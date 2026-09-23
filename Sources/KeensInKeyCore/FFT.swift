import Foundation
import Accelerate

/// Real-input FFT wrapper around vDSP's DFT, producing magnitude or power spectra.
public final class RealFFT {
    public enum Window { case hann, blackman, none }

    public let size: Int
    public let half: Int
    private let setup: vDSP_DFT_Setup
    private let inReal: UnsafeMutablePointer<Float>
    private let inImag: UnsafeMutablePointer<Float>
    private let outReal: UnsafeMutablePointer<Float>
    private let outImag: UnsafeMutablePointer<Float>
    private let windowBuf: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let hasWindow: Bool

    public init(size: Int, window: Window = .hann) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        self.half = size / 2
        guard let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            fatalError("Could not create DFT setup")
        }
        setup = s
        inReal = .allocate(capacity: half); inReal.initialize(repeating: 0, count: half)
        inImag = .allocate(capacity: half); inImag.initialize(repeating: 0, count: half)
        outReal = .allocate(capacity: half); outReal.initialize(repeating: 0, count: half)
        outImag = .allocate(capacity: half); outImag.initialize(repeating: 0, count: half)
        windowBuf = .allocate(capacity: size); windowBuf.initialize(repeating: 1, count: size)
        windowed = .allocate(capacity: size); windowed.initialize(repeating: 0, count: size)
        switch window {
        case .hann:
            vDSP_hann_window(windowBuf, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
            hasWindow = true
        case .blackman:
            vDSP_blkman_window(windowBuf, vDSP_Length(size), 0)
            hasWindow = true
        case .none:
            hasWindow = false
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
        inReal.deallocate(); inImag.deallocate(); outReal.deallocate(); outImag.deallocate()
        windowBuf.deallocate(); windowed.deallocate()
    }

    /// Runs the transform on `size` samples starting at `input`.
    private func transform(_ input: UnsafePointer<Float>) {
        let src: UnsafePointer<Float>
        if hasWindow {
            vDSP_vmul(input, 1, windowBuf, 1, windowed, 1, vDSP_Length(size))
            src = UnsafePointer(windowed)
        } else {
            src = input
        }
        src.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
            var split = DSPSplitComplex(realp: inReal, imagp: inImag)
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_DFT_Execute(setup, inReal, inImag, outReal, outImag)
    }

    /// Magnitude spectrum with `half + 1` bins (DC … Nyquist) written to `output`.
    public func magnitudes(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>) {
        transform(input)
        let dc = abs(outReal[0])
        let nyq = abs(outImag[0])
        outImag[0] = 0
        var split = DSPSplitComplex(realp: outReal, imagp: outImag)
        vDSP_zvabs(&split, 1, output, 1, vDSP_Length(half))
        output[0] = dc
        output[half] = nyq
    }

    /// Power spectrum (squared magnitude) with `half + 1` bins written to `output`.
    public func powers(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>) {
        transform(input)
        let dc = outReal[0] * outReal[0]
        let nyq = outImag[0] * outImag[0]
        outImag[0] = 0
        var split = DSPSplitComplex(realp: outReal, imagp: outImag)
        vDSP_zvmags(&split, 1, output, 1, vDSP_Length(half))
        output[0] = dc
        output[half] = nyq
    }

    /// Convenience: magnitude spectrum of an array (zero-padded / truncated to `size`).
    public func magnitudes(of samples: [Float]) -> [Float] {
        var input = samples
        if input.count < size { input.append(contentsOf: [Float](repeating: 0, count: size - input.count)) }
        var out = [Float](repeating: 0, count: half + 1)
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                magnitudes(ip.baseAddress!, into: op.baseAddress!)
            }
        }
        return out
    }
}

/// Small numeric helpers shared by the analyzers.
enum DSP {
    static func mean(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var m: Float = 0
        vDSP_meanv(x, 1, &m, vDSP_Length(x.count))
        return m
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }

    static func maxValue(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var m: Float = 0
        vDSP_maxv(x, 1, &m, vDSP_Length(x.count))
        return m
    }

    static func std(_ x: [Float]) -> Float {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        var acc: Float = 0
        for v in x { let d = v - m; acc += d * d }
        return sqrt(acc / Float(x.count))
    }

    static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(n))
        return r
    }

    /// Moving average with a centred window of `width` samples.
    static func movingAverage(_ x: [Float], width: Int) -> [Float] {
        let n = x.count
        guard n > 0, width > 1 else { return x }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: n)
        let halfW = width / 2
        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)
            out[i] = Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
        return out
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    static func percentile(_ x: [Float], _ p: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let idx = min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))
        return s[idx]
    }

    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

    /// Parabolic interpolation of a peak at integer index `i` of `y`; returns (offset, value).
    static func parabolicPeak(_ y: [Float], _ i: Int) -> (Double, Double) {
        guard i > 0, i < y.count - 1 else { return (0, Double(y[max(0, min(i, y.count - 1))])) }
        let a = Double(y[i - 1]), b = Double(y[i]), c = Double(y[i + 1])
        let denom = a - 2 * b + c
        if abs(denom) < 1e-12 { return (0, b) }
        let offset = 0.5 * (a - c) / denom
        let value = b - 0.25 * (a - c) * offset
        return (max(-1, min(1, offset)), value)
    }
}
