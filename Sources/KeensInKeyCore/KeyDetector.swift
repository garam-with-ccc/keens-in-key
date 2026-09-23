import Foundation
import Accelerate

/// Tone profiles used to classify a chroma vector into one of 24 keys.
public enum KeyProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case shaath      // Sha'ath (KeyFinder), tuned for electronic dance music
    case edma        // Essentia "edma" electronic dance music profile
    case krumhansl   // Krumhansl-Kessler
    case temperley   // Temperley (Kostka-Payne)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shaath: return "Sha'ath (KeyFinder, EDM)"
        case .edma: return "EDMA (Essentia, EDM)"
        case .krumhansl: return "Krumhansl-Kessler"
        case .temperley: return "Temperley"
        }
    }

    var major: [Double] {
        switch self {
        case .shaath: return [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
        case .edma: return [0.16519551, 0.04749226, 0.08293076, 0.06687112, 0.09994645, 0.09274123, 0.05294487, 0.13159476, 0.05218986, 0.07443653, 0.06940723, 0.0642494]
        case .krumhansl: return [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        case .temperley: return [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
        }
    }

    var minor: [Double] {
        switch self {
        case .shaath: return [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]
        case .edma: return [0.17235348, 0.05336489, 0.0761934, 0.10043649, 0.05621498, 0.08924425, 0.06202353, 0.11897834, 0.06931413, 0.06432578, 0.07444565, 0.06310506]
        case .krumhansl: return [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        case .temperley: return [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]
        }
    }
}

/// Output of the chroma analysis: a chromagram plus the global key estimate.
public struct KeyAnalysis: Sendable {
    public var estimate: KeyEstimate
    /// Chroma per frame (12 values each, C…B), un-normalised.
    public var chromagram: [[Float]]
    /// Seconds between chromagram frames.
    public var frameDuration: Double
}

/// Detects the musical key of a track using a constant-Q style chromagram
/// (semitone spectral kernels over 7 octaves) and tone-profile matching,
/// the approach used by KeyFinder / Mixxx.
public final class KeyDetector {
    public struct Config: Sendable {
        public var sampleRate: Double = 11025
        public var fftSize: Int = 16384
        public var hop: Int = 2048
        public var lowestMIDI: Int = 24       // C1
        /// C1…B5: fundamentals live here; higher octaves mostly add harmonics that bias towards the dominant.
        public var octaves: Int = 5
        /// Weights for reassigning energy from harmonics 2…5 back to their fundamentals (HPCP-style).
        public var harmonicWeights: [Double] = [0.5, 0.4, 0.3, 0.2]
        /// Per-octave gain multiplier applied from the lowest octave upwards (1 = flat, <1 favours bass).
        public var octaveDecay: Double = 1.0
        /// Compress magnitudes with log(1 + gain·m) before folding (0 = off).
        public var logCompression: Double = 0
        public var profile: KeyProfile = .shaath
        public var similarity: Similarity = .cosine
        /// Normalise each frame's chroma before accumulating so loud passages do not dominate.
        public var frameNormalization: Bool = false
        public var estimateTuning: Bool = true
        public init() {}
    }

    public enum Similarity: String, Codable, CaseIterable, Sendable, Identifiable {
        case cosine, pearson
        public var id: String { rawValue }
        public var displayName: String { self == .cosine ? "Cosine similarity" : "Pearson correlation" }
    }

    public let config: Config
    private let fft: RealFFT
    private let binWidth: Double
    private let semitoneBins: Int

    public init(config: Config = Config()) {
        self.config = config
        self.fft = RealFFT(size: config.fftSize, window: .blackman)
        self.binWidth = config.sampleRate / Double(config.fftSize)
        self.semitoneBins = config.octaves * 12
    }

    // MARK: Spectral kernel

    private struct Kernel {
        var starts: [Int]       // per semitone bin: first fft bin
        var weights: [[Float]]  // per semitone bin: weights for consecutive fft bins
    }

    /// Builds cosine-bump kernels centred on each semitone, shifted by `tuning` semitones.
    private func makeKernel(tuning: Double) -> Kernel {
        var starts = [Int](repeating: 0, count: semitoneBins)
        var weights = [[Float]](repeating: [], count: semitoneBins)
        let maxBin = fft.half
        for k in 0..<semitoneBins {
            let midi = Double(config.lowestMIDI + k) + tuning
            let fc = 440.0 * pow(2.0, (midi - 69.0) / 12.0)
            let fl = fc * pow(2.0, -0.5 / 12.0)
            let fu = fc * pow(2.0, 0.5 / 12.0)
            var lo = Int(ceil(fl / binWidth))
            var hi = Int(floor(fu / binWidth))
            let centreBin = Int((fc / binWidth).rounded())
            if hi < lo { lo = centreBin; hi = centreBin }
            lo = max(1, lo); hi = min(maxBin - 1, hi)
            if hi < lo { starts[k] = 0; weights[k] = []; continue }
            var w = [Float]()
            w.reserveCapacity(hi - lo + 1)
            for b in lo...hi {
                let f = Double(b) * binWidth
                let x = (f - fl) / (fu - fl)              // 0…1 across the band
                let weight = 0.5 * (1 - cos(2 * Double.pi * x))
                w.append(Float(max(weight, 0.05)))
            }
            starts[k] = lo
            weights[k] = w
        }
        return Kernel(starts: starts, weights: weights)
    }

    private func applyKernel(_ kernel: Kernel, spectrum: UnsafePointer<Float>, into bins: inout [Float]) {
        for k in 0..<semitoneBins {
            let w = kernel.weights[k]
            if w.isEmpty { bins[k] = 0; continue }
            bins[k] = w.withUnsafeBufferPointer { DSP.dot(spectrum + kernel.starts[k], $0.baseAddress!, w.count) }
        }
    }

    // MARK: Analysis

    /// Analyses mono samples at `config.sampleRate`.
    public func analyze(samples: [Float]) -> KeyAnalysis {
        let n = config.fftSize
        let hop = config.hop
        let frames = samples.count >= n ? (samples.count - n) / hop + 1 : 1
        var padded = samples
        if padded.count < n { padded.append(contentsOf: [Float](repeating: 0, count: n - padded.count)) }

        // Magnitude spectra for all frames.
        var spectra = [Float](repeating: 0, count: frames * (fft.half + 1))
        padded.withUnsafeBufferPointer { sp in
            spectra.withUnsafeMutableBufferPointer { op in
                for f in 0..<frames {
                    fft.magnitudes(sp.baseAddress! + f * hop, into: op.baseAddress! + f * (fft.half + 1))
                }
            }
        }

        // Tuning estimate: the kernel offset that captures the most energy.
        var tuning = 0.0
        if config.estimateTuning && frames > 0 {
            let offsets: [Double] = [-0.4, -0.3, -0.2, -0.1, 0, 0.1, 0.2, 0.3, 0.4]
            var best = -Double.infinity
            let step = max(1, frames / 60)
            var bins = [Float](repeating: 0, count: semitoneBins)
            for off in offsets {
                let kernel = makeKernel(tuning: off)
                var total = 0.0
                spectra.withUnsafeBufferPointer { sp in
                    for f in stride(from: 0, to: frames, by: step) {
                        applyKernel(kernel, spectrum: sp.baseAddress! + f * (fft.half + 1), into: &bins)
                        // Reward peaky (well-aligned) distributions: sum of squares.
                        var ss: Float = 0
                        vDSP_svesq(bins, 1, &ss, vDSP_Length(semitoneBins))
                        total += Double(ss)
                    }
                }
                if total > best { best = total; tuning = off }
            }
        }

        // Chromagram with the chosen tuning.
        let kernel = makeKernel(tuning: tuning)
        var chromagram = [[Float]](repeating: [Float](repeating: 0, count: 12), count: frames)
        var bins = [Float](repeating: 0, count: semitoneBins)
        var corrected = [Float](repeating: 0, count: semitoneBins)
        var global = [Double](repeating: 0, count: 12)
        // Sub-harmonic offsets in semitones for harmonics 2…6: 12, 19, 24, 28, 31.
        let harmonicOffsets = [12, 19, 24, 28, 31]
        let hw = config.harmonicWeights.map { Float($0) }
        var octaveGain = [Float](repeating: 1, count: semitoneBins)
        if config.octaveDecay != 1 {
            for k in 0..<semitoneBins { octaveGain[k] = Float(pow(config.octaveDecay, Double(k / 12))) }
        }
        let logGain = Float(config.logCompression)
        spectra.withUnsafeBufferPointer { sp in
            for f in 0..<frames {
                applyKernel(kernel, spectrum: sp.baseAddress! + f * (fft.half + 1), into: &bins)
                if logGain > 0 { for k in 0..<semitoneBins { bins[k] = log1pf(logGain * bins[k]) } }
                if !hw.isEmpty {
                    for k in 0..<semitoneBins { corrected[k] = bins[k] }
                    for k in 0..<semitoneBins {
                        let e = bins[k]
                        if e <= 0 { continue }
                        for (h, off) in harmonicOffsets.enumerated() where h < hw.count {
                            let j = k - off
                            if j >= 0 { corrected[j] += e * hw[h] }
                        }
                    }
                    for k in 0..<semitoneBins { bins[k] = corrected[k] }
                }
                if config.octaveDecay != 1 { for k in 0..<semitoneBins { bins[k] *= octaveGain[k] } }
                var c = [Float](repeating: 0, count: 12)
                for k in 0..<semitoneBins { c[(config.lowestMIDI + k) % 12] += bins[k] }
                chromagram[f] = c
                if config.frameNormalization {
                    let s = c.reduce(0, +)
                    if s > 0 { for i in 0..<12 { global[i] += Double(c[i] / s) } }
                } else {
                    for i in 0..<12 { global[i] += Double(c[i]) }
                }
            }
        }

        let estimate = KeyDetector.classify(chroma: global, profile: config.profile, similarity: config.similarity, tuning: tuning)
        return KeyAnalysis(estimate: estimate, chromagram: chromagram, frameDuration: Double(hop) / config.sampleRate)
    }

    /// Classifies a 12-bin chroma vector (C…B) against rotated tone profiles.
    public static func classify(chroma: [Double], profile: KeyProfile, similarity: Similarity = .cosine, tuning: Double = 0) -> KeyEstimate {
        precondition(chroma.count == 12)
        let sum = chroma.reduce(0, +)
        let norm = sum > 0 ? chroma.map { $0 / sum } : chroma
        let cMean = norm.reduce(0, +) / 12
        var candidates: [KeyCandidate] = []
        for mode in Mode.allCases {
            let p = mode == .major ? profile.major : profile.minor
            let pMean = p.reduce(0, +) / 12
            for root in 0..<12 {
                var dot = 0.0, na = 0.0, nb = 0.0
                for i in 0..<12 {
                    var pv = p[((i - root) % 12 + 12) % 12]
                    var cv = norm[i]
                    if similarity == .pearson { pv -= pMean; cv -= cMean }
                    dot += cv * pv
                    na += cv * cv
                    nb += pv * pv
                }
                let score = (na > 0 && nb > 0) ? dot / (sqrt(na) * sqrt(nb)) : 0
                candidates.append(KeyCandidate(key: MusicalKey(root: root, mode: mode), score: score))
            }
        }
        candidates.sort { $0.score > $1.score }
        let best = candidates[0]
        let second = candidates[1].score
        // Confidence from the margin over the runner-up. For cosine similarity the mapping was
        // calibrated against Essentia on real music: margin 0.005 ≈ 45%, 0.015 ≈ 85%, ≥ 0.02 ≈ 100%.
        let margin = best.score - second
        let confidence = max(0, min(1, similarity == .pearson ? margin * 4 : 0.25 + margin * 40))
        return KeyEstimate(key: best.key, confidence: confidence, strength: best.score, tuning: tuning, chroma: norm, candidates: Array(candidates.prefix(5)))
    }
}
