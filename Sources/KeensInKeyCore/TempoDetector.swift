import Foundation
import Accelerate

/// Per-frame band energies (linear power) from the onset STFT.
public struct BandEnergies: Sendable {
    public var low: [Float]     // < 150 Hz
    public var mid: [Float]     // 150 Hz … 4 kHz
    public var high: [Float]    // > 4 kHz
    public var total: [Float]
}

public struct TempoAnalysis: Sendable {
    public var estimate: TempoEstimate
    public var onsetEnvelope: [Float]
    public var frameRate: Double
    public var bands: BandEnergies
    /// Normalised autocorrelation of the onset envelope (index = lag in frames).
    public var autocorrelation: [Float]
}

/// Tempo estimation (autocorrelation of a spectral-flux onset envelope with a
/// log-normal tempo prior) and beat tracking (Ellis dynamic programming).
public final class TempoDetector {
    public struct Config: Sendable {
        public var sampleRate: Double = 22050
        public var fftSize: Int = 1024
        public var hop: Int = 128
        /// Search range for the raw periodicity.
        public var searchMinBPM: Double = 50
        public var searchMaxBPM: Double = 240
        /// Centre / width (octaves) of the tempo prior.
        public var priorBPM: Double = 125
        public var priorSigma: Double = 0.9
        /// A candidate lag is scored as ac(lag) × (1 + w2·ac(2·lag) + w4·ac(4·lag)) / (1 + w2 + w4):
        /// lags whose doubles and quadruples also fit the music (half-bar, bar) are preferred, which
        /// suppresses the 3:2 / 4:3 errors caused by dotted (tresillo) rhythms and off-beat hats.
        public var harmonicWeights: (Double, Double) = (1.0, 0.5)
        /// Extra weight (0…1) given to the onset flux of the bass bands (< 200 Hz), so kicks and bass
        /// notes dominate the periodicity estimate over hi-hats.
        public var bassWeight: Double = 0.0
        /// Onset flux compression: band energies are mapped through log(1 + μ·P/P₉₀) (μ > 0) instead of
        /// decibels, so loud onsets (kicks, snares) outweigh quiet broadband ones (hi-hats). 0 = decibels.
        public var fluxCompression: Double = 100
        /// Final BPM is folded (halved/doubled) into this range.
        public var rangeMin: Double = 70
        public var rangeMax: Double = 175
        public var tightness: Double = 100
        public init() {}
    }

    public let config: Config
    private let fft: RealFFT
    private let bandRanges: [(Int, Int)]
    private let lowBin: Int
    private let midBin: Int
    private let highBin: Int
    private let bassBands: Int

    public init(config: Config = Config()) {
        self.config = config
        self.fft = RealFFT(size: config.fftSize, window: .hann)
        let binWidth = config.sampleRate / Double(config.fftSize)
        let nBands = 40
        let fLo = 40.0
        let fHi = min(10000.0, config.sampleRate * 0.45)
        var ranges: [(Int, Int)] = []
        var prevHi = max(1, Int((fLo / binWidth).rounded()))
        for i in 1...nBands {
            let f = fLo * pow(fHi / fLo, Double(i) / Double(nBands))
            var hi = Int((f / binWidth).rounded())
            if hi <= prevHi { hi = prevHi + 1 }
            hi = min(hi, config.fftSize / 2)
            ranges.append((prevHi, hi))
            prevHi = hi
        }
        bandRanges = ranges
        bassBands = max(1, ranges.filter { Double($0.1) * binWidth <= 210 }.count)
        lowBin = max(1, Int((150.0 / binWidth).rounded()))
        midBin = max(lowBin + 1, Int((4000.0 / binWidth).rounded()))
        highBin = config.fftSize / 2
    }

    public var frameRate: Double { config.sampleRate / Double(config.hop) }

    // MARK: Onset envelope

    /// Spectral-flux onset strength on log-compressed log-spaced bands.
    func onsetEnvelope(samples: [Float]) -> (env: [Float], bands: BandEnergies) {
        let n = config.fftSize, hop = config.hop
        var padded = samples
        if padded.count < n { padded.append(contentsOf: [Float](repeating: 0, count: n - padded.count)) }
        let frames = (padded.count - n) / hop + 1
        let nb = bandRanges.count
        var bandPower = [Float](repeating: 0, count: frames * nb)
        var low = [Float](repeating: 0, count: frames)
        var mid = [Float](repeating: 0, count: frames)
        var high = [Float](repeating: 0, count: frames)
        var total = [Float](repeating: 0, count: frames)
        var spec = [Float](repeating: 0, count: fft.half + 1)
        padded.withUnsafeBufferPointer { sp in
            spec.withUnsafeMutableBufferPointer { op in
                let s = op.baseAddress!
                for f in 0..<frames {
                    fft.powers(sp.baseAddress! + f * hop, into: s)
                    for (b, r) in bandRanges.enumerated() {
                        var sum: Float = 0
                        vDSP_sve(s + r.0, 1, &sum, vDSP_Length(r.1 - r.0))
                        bandPower[f * nb + b] = sum
                    }
                    var l: Float = 0, m: Float = 0, h: Float = 0
                    vDSP_sve(s + 1, 1, &l, vDSP_Length(lowBin - 1))
                    vDSP_sve(s + lowBin, 1, &m, vDSP_Length(midBin - lowBin))
                    vDSP_sve(s + midBin, 1, &h, vDSP_Length(highBin - midBin + 1))
                    low[f] = l; mid[f] = m; high[f] = h; total[f] = l + m + h
                }
            }
        }
        var logP = [Float](repeating: 0, count: frames * nb)
        if config.fluxCompression > 0 {
            let ref = max(DSP.percentile(bandPower, 0.9), 1e-12)
            let mu = Float(config.fluxCompression) / ref
            for i in 0..<(frames * nb) { logP[i] = log1pf(mu * max(bandPower[i], 0)) }
        } else {
            let maxP = DSP.maxValue(bandPower)
            let floor = max(maxP * 1e-9, 1e-12)
            for i in 0..<(frames * nb) { logP[i] = 10 * log10f(max(bandPower[i], floor)) }
        }
        var env = [Float](repeating: 0, count: frames)
        let bw = Float(config.bassWeight)
        if frames > 1 {
            for f in 1..<frames {
                var acc: Float = 0
                var bass: Float = 0
                let cur = f * nb, prev = (f - 1) * nb
                for b in 0..<nb {
                    let d = logP[cur + b] - logP[prev + b]
                    if d > 0 {
                        acc += d
                        if b < bassBands { bass += d }
                    }
                }
                env[f] = (1 - bw) * acc / Float(nb) + bw * bass / Float(bassBands)
            }
        }
        return (env, BandEnergies(low: low, mid: mid, high: high, total: total))
    }

    // MARK: Tempo

    private func prior(bpm: Double) -> Double {
        let x = log2(bpm / config.priorBPM) / config.priorSigma
        return exp(-0.5 * x * x)
    }

    /// Normalised autocorrelation for lags 0…maxLag.
    func autocorrelation(_ x: [Float], maxLag: Int) -> [Float] {
        let n = x.count
        let m = min(maxLag, n - 2)
        guard m > 1 else { return [1] }
        let mean = DSP.mean(x)
        var z = [Float](repeating: 0, count: n)
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &z, 1, vDSP_Length(n))
        var ac = [Float](repeating: 0, count: m + 1)
        z.withUnsafeBufferPointer { p in
            for lag in 0...m {
                let count = n - lag
                ac[lag] = DSP.dot(p.baseAddress!, p.baseAddress! + lag, count) / Float(count)
            }
        }
        let a0 = ac[0]
        if a0 > 0 { for i in 0...m { ac[i] /= a0 } }
        return ac
    }

    /// Finds a refined (fractional) beat lag near `lag` by looking at multiples of the period.
    private func refineLag(_ lag: Double, ac: [Float]) -> Double {
        let maxLag = ac.count - 2
        for m in [8, 4, 2, 1] {
            let centre = lag * Double(m)
            let radius = max(2.0, lag * 0.2)
            let lo = Int((centre - radius).rounded()), hi = Int((centre + radius).rounded())
            guard lo >= 1, hi <= maxLag else { continue }
            var bestI = -1
            var bestV = -Float.infinity
            for i in lo...hi where ac[i] > bestV && ac[i] >= ac[i - 1] && ac[i] >= ac[i + 1] {
                bestV = ac[i]; bestI = i
            }
            guard bestI > 0 else { continue }
            let (off, _) = DSP.parabolicPeak(ac, bestI)
            let refined = (Double(bestI) + off) / Double(m)
            if abs(refined - lag) / lag < 0.08 { return refined }
        }
        return lag
    }

    /// Full analysis of mono samples at `config.sampleRate`.
    public func analyze(samples: [Float]) -> TempoAnalysis {
        let (env, bands) = onsetEnvelope(samples: samples)
        let fps = frameRate
        let frames = env.count
        let minLag = max(1, Int((60.0 * fps / config.searchMaxBPM).rounded(.down)))
        let maxSearchLag = Int((60.0 * fps / config.searchMinBPM).rounded(.up))
        let maxLag = min(frames - 2, max(maxSearchLag * 8 + 8, maxSearchLag + 2))

        guard frames > minLag + 4, maxLag > minLag + 2 else {
            let est = TempoEstimate(bpm: 0, confidence: 0, beats: [], downbeatPhase: 0, candidates: [])
            return TempoAnalysis(estimate: est, onsetEnvelope: env, frameRate: fps, bands: bands, autocorrelation: [])
        }

        let ac = autocorrelation(env, maxLag: maxLag)
        let searchHi = min(maxSearchLag, ac.count - 2)

        // Weighted tempogram peaks.
        var scores = [Float](repeating: 0, count: ac.count)
        let (w2, w4) = config.harmonicWeights
        for lag in minLag...searchHi {
            let bpm = 60.0 * fps / Double(lag)
            let base = Double(max(0, ac[lag]))
            var support = 1.0
            var wsum = 1.0
            if 2 * lag < ac.count { support += w2 * Double(max(0, ac[2 * lag])); wsum += w2 }
            if 4 * lag < ac.count { support += w4 * Double(max(0, ac[4 * lag])); wsum += w4 }
            scores[lag] = Float(base * support / wsum * prior(bpm: bpm))
        }
        var peaks: [(lag: Int, score: Float)] = []
        for lag in (minLag + 1)..<searchHi where scores[lag] > scores[lag - 1] && scores[lag] >= scores[lag + 1] && scores[lag] > 0 {
            peaks.append((lag, scores[lag]))
        }
        peaks.sort { $0.score > $1.score }
        guard let top = peaks.first else {
            let est = TempoEstimate(bpm: 0, confidence: 0, beats: [], downbeatPhase: 0, candidates: [])
            return TempoAnalysis(estimate: est, onsetEnvelope: env, frameRate: fps, bands: bands, autocorrelation: ac)
        }

        var candidates: [BPMCandidate] = []
        for p in peaks.prefix(8) {
            let (off, _) = DSP.parabolicPeak(scores, p.lag)
            let bpm = 60.0 * fps / (Double(p.lag) + off)
            candidates.append(BPMCandidate(bpm: (bpm * 100).rounded() / 100, score: Double(p.score / top.score)))
        }

        // Fold the winner into the preferred range.
        let (topOff, _) = DSP.parabolicPeak(scores, top.lag)
        var lag = Double(top.lag) + topOff
        var bpm = 60.0 * fps / lag
        while bpm < config.rangeMin && bpm * 2 <= config.rangeMax * 1.02 { bpm *= 2; lag /= 2 }
        while bpm > config.rangeMax && bpm / 2 >= config.rangeMin * 0.98 { bpm /= 2; lag *= 2 }

        // Refine the period from longer multiples, then track beats.
        lag = refineLag(lag, ac: ac)
        let beatFrames = BeatTracker.track(onset: env, period: lag, tightness: config.tightness)
        var beats = beatFrames.map { Double($0) * Double(config.hop) / config.sampleRate }

        // Final tempo from the beat sequence.
        var finalBPM = 60.0 * fps / lag
        var consistency = 0.0
        if beats.count >= 8 {
            let ibis = zip(beats.dropFirst(), beats).map { $0 - $1 }
            let med = DSP.median(ibis)
            let within = ibis.filter { abs($0 - med) / med < 0.04 }.count
            consistency = Double(within) / Double(ibis.count)
            if med > 0 {
                let n = Double(beats.count)
                let xs = (0..<beats.count).map(Double.init)
                let xm = xs.reduce(0, +) / n, ym = beats.reduce(0, +) / n
                var sxy = 0.0, sxx = 0.0
                for i in 0..<beats.count { sxy += (xs[i] - xm) * (beats[i] - ym); sxx += (xs[i] - xm) * (xs[i] - xm) }
                let slope = sxx > 0 ? sxy / sxx : med
                let period = consistency > 0.9 ? slope : med
                if period > 0 { finalBPM = 60.0 / period }
            }
        }
        // Keep the folded range even after refinement.
        while finalBPM < config.rangeMin && finalBPM * 2 <= config.rangeMax * 1.02 { finalBPM *= 2 }
        while finalBPM > config.rangeMax && finalBPM / 2 >= config.rangeMin * 0.98 { finalBPM /= 2 }
        if beats.isEmpty { beats = [] }

        let lagIdx = Int(lag.rounded())
        let periodicity = lagIdx < ac.count ? Double(max(0, ac[lagIdx])) : 0
        let confidence = DSP.clamp(0.6 * min(1, periodicity * 2.5) + 0.4 * consistency, 0, 1)

        let est = TempoEstimate(bpm: finalBPM, confidence: confidence, beats: beats, downbeatPhase: 0, candidates: candidates)
        return TempoAnalysis(estimate: est, onsetEnvelope: env, frameRate: fps, bands: bands, autocorrelation: ac)
    }
}

/// Dynamic-programming beat tracker (Ellis 2007), as in librosa.
public enum BeatTracker {
    public static func track(onset: [Float], period: Double, tightness: Double) -> [Int] {
        let n = onset.count
        guard n > 4, period >= 2 else { return [] }
        let std = max(DSP.std(onset), 1e-6)
        let normed = onset.map { $0 / std }

        // Local score: Gaussian-smoothed onset with width relative to the period.
        let w = Int(period.rounded())
        var window = [Float](repeating: 0, count: 2 * w + 1)
        for k in -w...w { window[k + w] = Float(exp(-0.5 * pow(Double(k) * 32.0 / period, 2))) }
        var localscore = [Float](repeating: 0, count: n)
        normed.withUnsafeBufferPointer { np in
            window.withUnsafeBufferPointer { wp in
                for i in 0..<n {
                    let lo = max(0, i - w), hi = min(n - 1, i + w)
                    var acc: Float = 0
                    vDSP_dotpr(np.baseAddress! + lo, 1, wp.baseAddress! + (lo - i + w), 1, &acc, vDSP_Length(hi - lo + 1))
                    localscore[i] = acc
                }
            }
        }

        let offsets = Array(Int((-2 * period).rounded())...Int((-period / 2).rounded()))
        let txwt = offsets.map { Float(-tightness * pow(log(Double(-$0) / period), 2)) }
        var cumscore = [Float](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)
        let thresh = 0.01 * DSP.maxValue(localscore)
        var firstBeat = true
        for i in 0..<n {
            var best = -Float.infinity
            var bestLoc = -1
            for (j, off) in offsets.enumerated() {
                let t = i + off
                if t < 0 { continue }
                let sc = txwt[j] + cumscore[t]
                if sc > best { best = sc; bestLoc = t }
            }
            if bestLoc < 0 {
                cumscore[i] = localscore[i]
                backlink[i] = -1
                continue
            }
            cumscore[i] = localscore[i] + best
            if firstBeat && localscore[i] < thresh {
                backlink[i] = -1
            } else {
                backlink[i] = bestLoc
                firstBeat = false
            }
        }

        // Last beat: last local maximum of cumscore that is at least half the median local max.
        var maxima: [Int] = []
        for i in 1..<(n - 1) where cumscore[i] > cumscore[i - 1] && cumscore[i] >= cumscore[i + 1] { maxima.append(i) }
        guard !maxima.isEmpty else { return [] }
        let med = DSP.median(maxima.map { Double(cumscore[$0]) })
        guard let last = maxima.last(where: { Double(cumscore[$0]) * 2 > med }) else { return [] }

        var beats: [Int] = []
        var b = last
        while b >= 0 {
            beats.append(b)
            b = backlink[b]
        }
        beats.reverse()
        guard beats.count > 1 else { return beats }

        // Trim weak leading / trailing beats.
        let meanScore = beats.reduce(Float(0)) { $0 + localscore[$1] } / Float(beats.count)
        let th = 0.5 * meanScore
        var start = 0, end = beats.count - 1
        while start < end && localscore[beats[start]] < th { start += 1 }
        while end > start && localscore[beats[end]] < th { end -= 1 }
        return Array(beats[start...end])
    }
}
