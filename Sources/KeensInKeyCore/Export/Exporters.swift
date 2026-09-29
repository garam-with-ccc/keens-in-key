import Foundation

/// A row of data for export (decoupled from the app's own track model).
public struct ExportTrack: Sendable {
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var fileSize: Int
    public var result: AnalysisResult?

    public init(url: URL, title: String, artist: String, album: String = "", genre: String = "", fileSize: Int = 0, result: AnalysisResult?) {
        self.url = url; self.title = title; self.artist = artist; self.album = album; self.genre = genre; self.fileSize = fileSize; self.result = result
    }
}

/// A playlist (or folder of playlists) to export alongside the collection.
public struct ExportPlaylist: Sendable {
    public var name: String
    public var isFolder: Bool
    /// Indexes into the exported track list (0-based), in playlist order.
    public var trackIndexes: [Int]
    public var children: [ExportPlaylist]
    public init(name: String, isFolder: Bool = false, trackIndexes: [Int] = [], children: [ExportPlaylist] = []) {
        self.name = name; self.isFolder = isFolder; self.trackIndexes = trackIndexes; self.children = children
    }
}

public enum Exporters {
    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    public static func csv(_ tracks: [ExportTrack], notation: KeyNotation) -> String {
        var lines = ["Artist,Title,Key,Key (Camelot),Key (Traditional),Open Key,BPM,Energy,Duration,Cue Points,File"]
        for t in tracks {
            let r = t.result
            let key = r?.key.key
            let cues = r?.cuePoints.map { "\($0.name)@\($0.time.timeStringMillis)" }.joined(separator: "; ") ?? ""
            let row = [
                t.artist, t.title,
                key?.formatted(notation) ?? "", key?.camelot ?? "", key?.traditional ?? "", key?.openKey ?? "",
                r.map { String(format: "%.2f", $0.tempo.bpm) } ?? "",
                r.map { String($0.energy) } ?? "",
                r.map { $0.duration.timeString } ?? "",
                cues, t.url.path,
            ].map(csvEscape).joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func m3u(_ tracks: [ExportTrack]) -> String {
        var lines = ["#EXTM3U"]
        for t in tracks {
            let dur = Int(t.result?.duration ?? 0)
            var label = "\(t.artist) - \(t.title)"
            if let k = t.result?.key.key { label = "\(k.camelot) \(label)" }
            lines.append("#EXTINF:\(dur),\(label)")
            lines.append(t.url.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// rekordbox only accepts its own palette for hot cue colours.
    static func rekordboxColor(_ kind: CueKind) -> (Int, Int, Int) {
        switch kind {
        case .intro: return (40, 226, 20)        // green
        case .verse: return (48, 90, 255)        // blue
        case .build: return (255, 140, 0)        // orange
        case .drop: return (230, 40, 40)         // red
        case .breakdown: return (0, 224, 255)    // cyan
        case .outro: return (180, 50, 255)       // purple
        case .custom: return (255, 200, 0)       // yellow
        }
    }

    static func rekordboxLocation(_ url: URL) -> String {
        let allowed = CharacterSet.urlPathAllowed
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file://localhost" + path
    }

    /// rekordbox.xml collection with tempo grid and hot cues, importable by Pioneer rekordbox.
    public static func rekordboxXML(_ tracks: [ExportTrack], playlistName: String = "Keens In Key", notation: KeyNotation = .camelot, appVersion: String = "1.0") -> String {
        rekordboxXML(tracks, playlists: [ExportPlaylist(name: playlistName, trackIndexes: Array(0..<tracks.count))], notation: notation, appVersion: appVersion)
    }

    static func rekordboxPlaylistNode(_ p: ExportPlaylist, indent: String) -> String {
        if p.isFolder {
            var out = "\(indent)<NODE Type=\"0\" Name=\"\(xmlEscape(p.name))\" Count=\"\(p.children.count)\">\n"
            for c in p.children { out += rekordboxPlaylistNode(c, indent: indent + "  ") }
            return out + "\(indent)</NODE>\n"
        }
        var out = "\(indent)<NODE Name=\"\(xmlEscape(p.name))\" Type=\"1\" KeyType=\"0\" Entries=\"\(p.trackIndexes.count)\">\n"
        for i in p.trackIndexes { out += "\(indent)  <TRACK Key=\"\(i + 1)\"/>\n" }
        return out + "\(indent)</NODE>\n"
    }

    /// rekordbox.xml with an arbitrary playlist / folder tree.
    public static func rekordboxXML(_ tracks: [ExportTrack], playlists: [ExportPlaylist], notation: KeyNotation = .camelot, appVersion: String = "1.0") -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<DJ_PLAYLISTS Version=\"1.0.0\">\n"
        out += "  <PRODUCT Name=\"Keens In Key\" Version=\"\(xmlEscape(appVersion))\" Company=\"keens-in-key\"/>\n"
        out += "  <COLLECTION Entries=\"\(tracks.count)\">\n"
        for (i, t) in tracks.enumerated() {
            let id = i + 1
            let r = t.result
            let kind: String
            switch t.url.pathExtension.lowercased() {
            case "mp3": kind = "MP3 File"
            case "m4a", "mp4": kind = "M4A File"
            case "wav": kind = "WAV File"
            case "aif", "aiff": kind = "AIFF File"
            case "flac": kind = "FLAC File"
            default: kind = "Audio File"
            }
            var attrs = "TrackID=\"\(id)\" Name=\"\(xmlEscape(t.title))\" Artist=\"\(xmlEscape(t.artist))\" Album=\"\(xmlEscape(t.album))\" Genre=\"\(xmlEscape(t.genre))\" Kind=\"\(kind)\" Size=\"\(t.fileSize)\""
            if let r {
                attrs += " TotalTime=\"\(Int(r.duration.rounded()))\" AverageBpm=\"\(String(format: "%.2f", r.tempo.bpm))\" Tonality=\"\(xmlEscape(r.key.key.formatted(notation)))\""
                attrs += " Comments=\"\(xmlEscape("\(r.key.key.formatted(notation)) - Energy \(r.energy)"))\""
            }
            attrs += " Location=\"\(xmlEscape(rekordboxLocation(t.url)))\""
            out += "    <TRACK \(attrs)>\n"
            if let r, !r.tempo.beats.isEmpty, r.tempo.bpm > 0 {
                out += "      <TEMPO Inizio=\"\(String(format: "%.3f", r.tempo.firstDownbeat))\" Bpm=\"\(String(format: "%.2f", r.tempo.bpm))\" Metro=\"4/4\" Battito=\"1\"/>\n"
                for (ci, cue) in r.cuePoints.prefix(8).enumerated() {
                    let rgb = rekordboxColor(cue.kind)
                    let color = " Red=\"\(rgb.0)\" Green=\"\(rgb.1)\" Blue=\"\(rgb.2)\""
                    out += "      <POSITION_MARK Name=\"\(xmlEscape(cue.name))\" Type=\"0\" Start=\"\(String(format: "%.3f", cue.time))\" Num=\"\(ci)\"\(color)/>\n"
                    out += "      <POSITION_MARK Name=\"\(xmlEscape(cue.name))\" Type=\"0\" Start=\"\(String(format: "%.3f", cue.time))\" Num=\"-1\"/>\n"
                }
            }
            out += "    </TRACK>\n"
        }
        out += "  </COLLECTION>\n"
        out += "  <PLAYLISTS>\n    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(playlists.count)\">\n"
        for p in playlists { out += rekordboxPlaylistNode(p, indent: "      ") }
        out += "    </NODE>\n  </PLAYLISTS>\n</DJ_PLAYLISTS>\n"
        return out
    }
}
