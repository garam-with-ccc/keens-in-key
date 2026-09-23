import Foundation
import KeensInKeyCore

enum TrackStatus: String, Codable, Hashable {
    case pending, queued, analyzing, done, failed
}

/// One file in the library.
struct Track: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String = ""
    var genre: String = ""
    var fileSize: Int = 0
    var duration: Double?
    var existingTags = TagFields()
    var result: AnalysisResult?
    var status: TrackStatus = .pending
    var progress: Double = 0
    var stage: String = ""
    var errorMessage: String?
    var tagsWrittenAt: Date?
    var addedAt: Date = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { url.lastPathComponent }
    var format: String { url.pathExtension.uppercased() }
    var key: MusicalKey? { result?.key.key }
    var bpm: Double? { result?.tempo.bpm }
    var energy: Int? { result?.energy }
    var displayTitle: String { title.isEmpty ? url.deletingPathExtension().lastPathComponent : title }

    // Sortable values for the table.
    var keySortValue: Int {
        guard let k = key else { return 999 }
        return k.camelotNumber * 2 + (k.mode == .major ? 1 : 0)
    }
    var bpmSortValue: Double { bpm ?? -1 }
    var energySortValue: Int { energy ?? -1 }
    var durationSortValue: Double { result?.duration ?? duration ?? -1 }
    var cueCountValue: Int { result?.cuePoints.count ?? -1 }
    var statusSortValue: Int {
        switch status {
        case .analyzing: return 0
        case .queued: return 1
        case .pending: return 2
        case .failed: return 3
        case .done: return 4
        }
    }
    var tagsSortValue: Int { tagsWrittenAt == nil ? 0 : 1 }

    var isMissing: Bool { !FileManager.default.fileExists(atPath: path) }

    static func make(url: URL) -> Track {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Track(path: url.path, title: url.deletingPathExtension().lastPathComponent, artist: "",
                     fileSize: (attrs?[.size] as? Int) ?? 0)
    }
}
