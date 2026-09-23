import Foundation
import AVFoundation
import Accelerate

public struct DecodedAudio: Sendable {
    public var sampleRate: Double
    public var samples: [Float]          // mono
    public var duration: Double          // seconds
    public var sourceSampleRate: Double
    public var sourceChannels: Int

    public init(sampleRate: Double, samples: [Float], duration: Double, sourceSampleRate: Double, sourceChannels: Int) {
        self.sampleRate = sampleRate
        self.samples = samples
        self.duration = duration
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
    }
}

public enum AudioDecodeError: Error, LocalizedError {
    case unreadable(String)
    case empty
    case converter(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "Could not read audio: \(m)"
        case .empty: return "The file contains no audio"
        case .converter(let m): return "Sample rate conversion failed: \(m)"
        }
    }
}

/// Decodes any format supported by Core Audio (MP3, AAC/M4A, ALAC, WAV, AIFF, FLAC, CAF) to mono float samples.
public enum AudioDecoder {
    public static let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "m4b", "alac"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func decodeMono(url: URL, targetSampleRate: Double? = nil, maxSeconds: Double? = nil) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioDecodeError.unreadable("file not found")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioDecodeError.unreadable(error.localizedDescription)
        }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, ch > 0 else { throw AudioDecodeError.empty }
        let framesToRead = maxSeconds.map { min(totalFrames, Int($0 * sr)) } ?? totalFrames

        var mono = [Float]()
        mono.reserveCapacity(framesToRead)
        let chunk = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw AudioDecodeError.unreadable("buffer allocation failed")
        }
        var mixBuf = [Float](repeating: 0, count: chunk)
        let scale = 1.0 / Float(ch)
        while mono.count < framesToRead {
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(min(chunk, framesToRead - mono.count))) }
            catch { throw AudioDecodeError.unreadable(error.localizedDescription) }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            if ch == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            } else {
                mixBuf.withUnsafeMutableBufferPointer { mp in
                    vDSP_vclr(mp.baseAddress!, 1, vDSP_Length(n))
                    for c in 0..<ch {
                        vDSP_vadd(mp.baseAddress!, 1, data[c], 1, mp.baseAddress!, 1, vDSP_Length(n))
                    }
                    var s = scale
                    vDSP_vsmul(mp.baseAddress!, 1, &s, mp.baseAddress!, 1, vDSP_Length(n))
                }
                mono.append(contentsOf: mixBuf[0..<n])
            }
        }
        guard !mono.isEmpty else { throw AudioDecodeError.empty }
        let duration = Double(totalFrames) / sr
        var outRate = sr
        if let t = targetSampleRate, abs(t - sr) > 0.5 {
            mono = try Resampler.resample(mono, from: sr, to: t)
            outRate = t
        }
        return DecodedAudio(sampleRate: outRate, samples: mono, duration: duration, sourceSampleRate: sr, sourceChannels: ch)
    }

    /// Duration in seconds without decoding.
    public static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}

/// High-quality sample-rate conversion using AVAudioConverter.
public enum Resampler {
    public static func resample(_ input: [Float], from: Double, to: Double) throws -> [Float] {
        if abs(from - to) < 0.5 || input.isEmpty { return input }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw AudioDecodeError.converter("format")
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        // Feed the converter in chunks to keep memory bounded.
        let chunkFrames = 1 << 16
        var position = 0
        var output = [Float]()
        output.reserveCapacity(Int(Double(input.count) * to / from) + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Int(Double(chunkFrames) * to / from) + 4096)) else {
            throw AudioDecodeError.converter("buffer")
        }
        var finished = false
        while !finished {
            var error: NSError?
            outBuf.frameLength = 0
            let status = conv.convert(to: outBuf, error: &error) { requested, outStatus in
                if position >= input.count {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let n = min(chunkFrames, input.count - position)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                input.withUnsafeBufferPointer { ip in
                    inBuf.floatChannelData![0].update(from: ip.baseAddress! + position, count: n)
                }
                inBuf.frameLength = AVAudioFrameCount(n)
                position += n
                outStatus.pointee = .haveData
                return inBuf
            }
            if let error { throw AudioDecodeError.converter(error.localizedDescription) }
            let produced = Int(outBuf.frameLength)
            if produced > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: produced))
            }
            switch status {
            case .endOfStream, .error:
                finished = true
            case .inputRanDry:
                if position >= input.count && produced == 0 { finished = true }
            default:
                if produced == 0 && position >= input.count { finished = true }
            }
        }
        return output
    }
}
