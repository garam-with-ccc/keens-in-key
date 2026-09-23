import Foundation
import AVFoundation

/// Tag values we read from / write to files.
public struct TagFields: Codable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var comment: String?
    public var grouping: String?
    public var initialKey: String?
    public var bpm: String?
    public var energy: String?   // TXXX:ENERGYLEVEL / freeform

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil, comment: String? = nil,
                grouping: String? = nil, initialKey: String? = nil, bpm: String? = nil, energy: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.genre = genre; self.comment = comment
        self.grouping = grouping; self.initialKey = initialKey; self.bpm = bpm; self.energy = energy
    }
}

/// Reads and writes iTunes-style metadata in MP4/M4A files using AVFoundation (passthrough re-mux, no re-encoding).
public enum MP4Tagger {
    static let freeformKeySpace = AVMetadataKeySpace(rawValue: "itlk")
    static let initialKeyKey = "com.apple.iTunes.initialkey"
    static let energyKey = "com.apple.iTunes.energylevel"

    public static func read(_ url: URL) async throws -> TagFields {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        var f = TagFields()
        for it in items {
            guard let id = it.identifier?.rawValue else { continue }
            let value = try? await it.load(.value)
            let str = (value as? String) ?? (value as? NSNumber).map { $0.stringValue }
            switch id {
            case AVMetadataIdentifier.iTunesMetadataSongName.rawValue: f.title = str
            case AVMetadataIdentifier.iTunesMetadataArtist.rawValue: f.artist = str
            case AVMetadataIdentifier.iTunesMetadataAlbum.rawValue: f.album = str
            case AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue: f.genre = str
            case AVMetadataIdentifier.iTunesMetadataUserComment.rawValue: f.comment = str
            case AVMetadataIdentifier.iTunesMetadataGrouping.rawValue, "itsk/%A9grp": if f.grouping == nil { f.grouping = str }
            case AVMetadataIdentifier.iTunesMetadataBeatsPerMin.rawValue: f.bpm = str
            case "itlk/\(initialKeyKey)": f.initialKey = str
            case "itlk/\(energyKey)": f.energy = str
            default: break
            }
        }
        return f
    }

    /// Writes the non-nil fields of `fields` (nil fields are left untouched, empty strings remove the atom).
    public static func write(_ fields: TagFields, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let existing = try await asset.load(.metadata)

        var replaced = Set<String>()
        var newItems: [AVMetadataItem] = []
        func add(_ identifier: String, _ value: Any?) {
            replaced.insert(identifier)
            guard let value else { return }
            if let s = value as? String, s.isEmpty { return }
            let m = AVMutableMetadataItem()
            m.identifier = AVMetadataIdentifier(rawValue: identifier)
            m.value = value as? (NSCopying & NSObjectProtocol)
            m.extendedLanguageTag = "und"
            newItems.append(m)
        }
        func addFreeform(_ key: String, _ value: String?) {
            replaced.insert("itlk/\(key)")
            guard let value, !value.isEmpty else { return }
            let m = AVMutableMetadataItem()
            m.keySpace = freeformKeySpace
            m.key = key as NSString
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            m.extendedLanguageTag = "und"
            newItems.append(m)
        }
        if let v = fields.title { add(AVMetadataIdentifier.iTunesMetadataSongName.rawValue, v as NSString) }
        if let v = fields.artist { add(AVMetadataIdentifier.iTunesMetadataArtist.rawValue, v as NSString) }
        if let v = fields.album { add(AVMetadataIdentifier.iTunesMetadataAlbum.rawValue, v as NSString) }
        if let v = fields.genre { add(AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue, v as NSString) }
        if let v = fields.comment { add(AVMetadataIdentifier.iTunesMetadataUserComment.rawValue, v as NSString) }
        if let v = fields.grouping {
            add("itsk/%A9grp", v as NSString)
            replaced.insert(AVMetadataIdentifier.iTunesMetadataGrouping.rawValue)
        }
        if let v = fields.bpm {
            let n = Int(Double(v)?.rounded() ?? 0)
            add(AVMetadataIdentifier.iTunesMetadataBeatsPerMin.rawValue, n > 0 ? NSNumber(value: n) : nil)
        }
        if let v = fields.initialKey { addFreeform(initialKeyKey, v) }
        if let v = fields.energy { addFreeform(energyKey, v) }

        let kept = existing.filter { !replaced.contains($0.identifier?.rawValue ?? "") }
        let items = kept + newItems

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ID3Error.io("cannot create export session")
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).kik-\(UUID().uuidString.prefix(8)).m4a")
        try? FileManager.default.removeItem(at: tmp)
        export.outputFileType = .m4a
        export.outputURL = tmp
        export.metadata = items
        await export.export()
        if let error = export.error {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io(error.localizedDescription)
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io("export failed with status \(export.status.rawValue)")
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io(error.localizedDescription)
        }
    }
}
