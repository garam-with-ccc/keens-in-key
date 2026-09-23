import XCTest
@testable import KeensInKeyCore

final class ResamplerTests: XCTestCase {
    /// A click train must keep its exact spacing after resampling, including across internal chunk boundaries.
    func testClickTrainSpacingIsPreserved() throws {
        let sr = 44100.0
        let seconds = 24.0
        var x = [Float](repeating: 0, count: Int(sr * seconds))
        let spacing = 0.5
        var t = 0.25
        while t < seconds { x[Int(t * sr)] = 1; t += spacing }
        let y = try Resampler.resample(x, from: sr, to: 22050)
        XCTAssertEqual(Double(y.count), Double(x.count) / 2, accuracy: 64)

        // Locate peaks.
        var peaks: [Int] = []
        var i = 0
        while i < y.count {
            if y[i] > 0.2 {
                var best = i
                var j = i
                while j < min(y.count, i + 40) { if y[j] > y[best] { best = j }; j += 1 }
                peaks.append(best)
                i = best + 40
            } else { i += 1 }
        }
        XCTAssertEqual(peaks.count, Int((seconds - 0.25) / spacing) + 1)
        let gaps = zip(peaks.dropFirst(), peaks).map { $0 - $1 }
        for g in gaps { XCTAssertEqual(g, Int(spacing * 22050), "gap \(g) should be \(Int(spacing * 22050))") }
    }

    func testDownsampleChainLength() throws {
        let x = [Float](repeating: 0.1, count: 44100 * 10)
        let y22 = try Resampler.resample(x, from: 44100, to: 22050)
        let y11 = try Resampler.resample(y22, from: 22050, to: 11025)
        XCTAssertEqual(y22.count, 22050 * 10, accuracy: 64)
        XCTAssertEqual(y11.count, 11025 * 10, accuracy: 64)
    }
}
