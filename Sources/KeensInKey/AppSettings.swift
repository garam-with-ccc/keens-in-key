import Foundation
import SwiftUI
import KeensInKeyCore

/// User preferences (persisted in UserDefaults).
@Observable
final class AppSettings {
    var analysis: TrackAnalyzer.Options { didSet { save() } }
    var tagOptions: TagWritingOptions { didSet { save() } }
    var quantize: QuantizeMode { didSet { save() } }
    var concurrency: Int { didSet { save() } }
    var displayNotation: KeyNotation { didSet { save() } }
    var bpmDisplayDecimals: Int { didSet { save() } }
    var autoAnalyzeOnAdd: Bool { didSet { save() } }

    private static let key = "kik.settings.v1"

    struct Stored: Codable {
        var analysis: TrackAnalyzer.Options
        var tagOptions: TagWritingOptions
        var quantize: QuantizeMode
        var concurrency: Int
        var displayNotation: KeyNotation
        var bpmDisplayDecimals: Int
        var autoAnalyzeOnAdd: Bool
    }

    init() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if let data = UserDefaults.standard.data(forKey: AppSettings.key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            analysis = s.analysis
            tagOptions = s.tagOptions
            quantize = s.quantize
            concurrency = max(1, min(16, s.concurrency))
            displayNotation = s.displayNotation
            bpmDisplayDecimals = s.bpmDisplayDecimals
            autoAnalyzeOnAdd = s.autoAnalyzeOnAdd
        } else {
            analysis = TrackAnalyzer.Options()
            tagOptions = TagWritingOptions()
            quantize = .bar
            concurrency = max(1, min(8, cores / 2))
            displayNotation = .camelot
            bpmDisplayDecimals = 2
            autoAnalyzeOnAdd = true
        }
    }

    private func save() {
        let s = Stored(analysis: analysis, tagOptions: tagOptions, quantize: quantize, concurrency: concurrency,
                       displayNotation: displayNotation, bpmDisplayDecimals: bpmDisplayDecimals, autoAnalyzeOnAdd: autoAnalyzeOnAdd)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: AppSettings.key) }
    }

    func reset() {
        analysis = TrackAnalyzer.Options()
        tagOptions = TagWritingOptions()
        quantize = .bar
        concurrency = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        displayNotation = .camelot
        bpmDisplayDecimals = 2
        autoAnalyzeOnAdd = true
    }

    func formatBPM(_ bpm: Double) -> String { String(format: "%.\(bpmDisplayDecimals)f", bpm) }
}
