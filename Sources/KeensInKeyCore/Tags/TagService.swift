import Foundation
import AVFoundation

/// How the comment field is updated.
public enum CommentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case prepend, append, overwrite
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .prepend: return "Add before existing comment"
        case .append: return "Add after existing comment"
        case .overwrite: return "Overwrite comment"
        }
    }
}

/// Personalisation of what gets written to the files (mirrors Mixed In Key's "Personalize" tab).
public struct TagWritingOptions: Codable, Hashable, Sendable {
    public var notation: KeyNotation = .camelot
    public var writeInitialKey = true
    public var writeComment = true
    public var commentFormat = "{key} - Energy {energy}"
    public var commentMode: CommentMode = .prepend
    public var writeGrouping = false
    public var groupingFormat = "{key}"
    public var writeBPM = true
    public var bpmDecimals = 0
    public var writeEnergyTag = true
    public var prefixTitle = false
    public var titleFormat = "{key} - {title}"
    public var renameFile = false
    public var fileNameFormat = "{key} - {artist} - {title}"
    public var autoWriteAfterAnalysis = false

    public init() {}

    /// Expands {key}, {energy}, {bpm}, {title}, {artist}, {camelot}, {openkey}, {traditional} tokens.
    public func expand(_ format: String, key: MusicalKey, energy: Int, bpm: Double, title: String, artist: String) -> String {
        var s = format
        let pairs: [(String, String)] = [
            ("{key}", key.formatted(notation)),
            ("{camelot}", key.camelot),
            ("{openkey}", key.openKey),
            ("{traditional}", key.traditional),
            ("{energy}", String(energy)),
            ("{bpm}", TagWritingOptions.formatBPM(bpm, decimals: bpmDecimals)),
            ("{title}", title),
            ("{artist}", artist),
        ]
        for (k, v) in pairs { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        return s
    }

    public static func formatBPM(_ bpm: Double, decimals: Int) -> String {
        let d = max(0, min(2, decimals))
        return String(format: "%.\(d)f", bpm)
    }
}

/// Result of writing tags to one file.
public struct TagWriteOutcome: Sendable {
    public var newURL: URL
    public var fields: TagFields
}

/// Format-agnostic tag reading and writing.
public enum TagService {
    public enum Format: String, Sendable {
        case mp3, aiff, wav, flac, mp4, unsupported
    }

    public static func format(of url: URL) -> Format {
        switch url.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "aif", "aiff", "aifc": return .aiff
        case "wav", "wave": return .wav
        case "flac": return .flac
        case "m4a", "mp4", "m4b", "aac", "alac": return .mp4
        default: return .unsupported
        }
    }

    // MARK: Reading

    /// Reads title/artist/etc. plus any existing key/BPM/comment tags.
    public static func read(_ url: URL) async -> TagFields {
        switch format(of: url) {
        case .mp3:
            if let (tag, _) = try? ID3File.readMP3(url), let tag { return fields(from: tag) }
        case .aiff, .wav:
            if let tag = try? ID3File.readChunked(url) { return fields(from: tag) }
            return await readViaAVFoundation(url)
        case .flac:
            if let vc = try? FLACFile.readComment(url) {
                return TagFields(title: vc.first("TITLE"), artist: vc.first("ARTIST"), album: vc.first("ALBUM"), genre: vc.first("GENRE"),
                                 comment: vc.first("COMMENT") ?? vc.first("DESCRIPTION"), grouping: vc.first("GROUPING"),
                                 initialKey: vc.first("INITIALKEY") ?? vc.first("KEY"), bpm: vc.first("BPM"), energy: vc.first("ENERGYLEVEL"))
            }
        case .mp4:
            if let f = try? await MP4Tagger.read(url) { return f }
        case .unsupported:
            break
        }
        return await readViaAVFoundation(url)
    }

    static func fields(from tag: ID3Tag) -> TagFields {
        TagFields(title: tag.title, artist: tag.artist, album: tag.album, genre: tag.genre, comment: tag.comment() ?? tag.userText("comment"),
                  grouping: tag.grouping, initialKey: tag.initialKey, bpm: tag.bpm, energy: tag.userText("ENERGYLEVEL"))
    }

    static func readViaAVFoundation(_ url: URL) async -> TagFields {
        var f = TagFields()
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return f }
        for it in items {
            guard let key = it.commonKey else { continue }
            let value = (try? await it.load(.stringValue)) ?? nil
            switch key {
            case .commonKeyTitle: f.title = value
            case .commonKeyArtist: f.artist = value
            case .commonKeyAlbumName: f.album = value
            default: break
            }
        }
        return f
    }

    // MARK: Writing

    /// Builds the fields to write for an analysed track according to `options`.
    public static func fields(for result: AnalysisResult, existing: TagFields, options: TagWritingOptions, title: String, artist: String) -> TagFields {
        let key = result.key.key
        var f = TagFields()
        func expand(_ fmt: String) -> String {
            options.expand(fmt, key: key, energy: result.energy, bpm: result.tempo.bpm, title: title, artist: artist)
        }
        if options.writeInitialKey { f.initialKey = key.formatted(options.notation) }
        if options.writeBPM { f.bpm = TagWritingOptions.formatBPM(result.tempo.bpm, decimals: options.bpmDecimals) }
        if options.writeEnergyTag { f.energy = String(result.energy) }
        if options.writeGrouping { f.grouping = expand(options.groupingFormat) }
        if options.writeComment {
            let tagText = expand(options.commentFormat)
            let old = stripPreviousTag(existing.comment ?? "")
            switch options.commentMode {
            case .overwrite: f.comment = tagText
            case .prepend: f.comment = old.isEmpty ? tagText : "\(tagText) - \(old)"
            case .append: f.comment = old.isEmpty ? tagText : "\(old) - \(tagText)"
            }
        }
        if options.prefixTitle {
            let baseTitle = stripPreviousTag(title)
            f.title = expand(options.titleFormat.replacingOccurrences(of: "{title}", with: baseTitle))
        }
        return f
    }

    /// Removes a previously written "8A - Energy 7 - " style prefix so re-writing does not stack tags.
    public static func stripPreviousTag(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespaces)
        // Patterns: "8A - Energy 7 - rest", "8A - Energy 7", "8A - rest", "Am - Energy 7 - rest", "1m - rest"
        let pattern = #"^\s*(\d{1,2}[ABab]|\d{1,2}[md]|[A-G][#b]?m?)(\s*-\s*Energy\s*\d{1,2})?(\s*-\s*|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = regex.firstMatch(in: text, range: range) {
                // Only strip when the prefix is followed by " - " or covers the whole string.
                let full = m.range(at: 0)
                text = String(text[Range(full, in: text)!.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    /// Writes `fields` to the file. Returns the (possibly renamed) URL.
    public static func write(_ fields: TagFields, to url: URL, rename: String? = nil) async throws -> URL {
        switch format(of: url) {
        case .mp3:
            var tag = (try ID3File.readMP3(url).tag) ?? ID3Tag(version: 3)
            apply(fields, to: &tag)
            try ID3File.writeMP3(tag, to: url)
        case .aiff, .wav:
            var tag = (try ID3File.readChunked(url)) ?? ID3Tag(version: 3)
            apply(fields, to: &tag)
            try ID3File.writeChunked(tag, to: url)
        case .flac:
            var vc = (try FLACFile.readComment(url)) ?? VorbisComment()
            if let v = fields.title { vc.set("TITLE", v) }
            if let v = fields.artist { vc.set("ARTIST", v) }
            if let v = fields.album { vc.set("ALBUM", v) }
            if let v = fields.genre { vc.set("GENRE", v) }
            if let v = fields.comment { vc.set("COMMENT", v) }
            if let v = fields.grouping { vc.set("GROUPING", v) }
            if let v = fields.initialKey { vc.set("INITIALKEY", v) }
            if let v = fields.bpm { vc.set("BPM", v) }
            if let v = fields.energy { vc.set("ENERGYLEVEL", v) }
            try FLACFile.writeComment(vc, to: url)
        case .mp4:
            try await MP4Tagger.write(fields, to: url)
        case .unsupported:
            throw ID3Error.io("Tag writing is not supported for .\(url.pathExtension) files")
        }
        guard let rename, !rename.isEmpty else { return url }
        let safe = sanitizeFileName(rename)
        let target = url.deletingLastPathComponent().appendingPathComponent(safe).appendingPathExtension(url.pathExtension)
        if target.lastPathComponent == url.lastPathComponent { return url }
        var final = target
        var n = 2
        while FileManager.default.fileExists(atPath: final.path) {
            final = url.deletingLastPathComponent().appendingPathComponent("\(safe) (\(n))").appendingPathExtension(url.pathExtension)
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: final)
        return final
    }

    static func apply(_ fields: TagFields, to tag: inout ID3Tag) {
        if let v = fields.title { tag.title = v }
        if let v = fields.artist { tag.artist = v }
        if let v = fields.album { tag.album = v }
        if let v = fields.genre { tag.genre = v }
        if let v = fields.comment { tag.setComment(v) }
        if let v = fields.grouping { tag.grouping = v }
        if let v = fields.initialKey { tag.initialKey = v }
        if let v = fields.bpm { tag.bpm = v }
        if let v = fields.energy { tag.setUserText("ENERGYLEVEL", v) }
    }

    public static func sanitizeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|\0")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(200))
    }
}
