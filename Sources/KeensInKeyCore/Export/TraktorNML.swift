import Foundation

/// Native Instruments Traktor collection export (.nml) with key, tempo grid marker and hot cues.
public enum TraktorNML {
    /// Traktor MUSICAL_KEY values: 0…11 = C…B major, 12…23 = C…B minor.
    public static func musicalKeyValue(_ key: MusicalKey) -> Int {
        key.mode == .major ? key.root : 12 + key.root
    }

    static func esc(_ s: String) -> String { Exporters.xmlEscape(s) }

    /// Traktor stores the directory as "/:Users/:name/:Music/:" — every component prefixed with "/:".
    static func location(_ url: URL) -> (dir: String, file: String, volume: String) {
        let comps = url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        let dir = comps.map { "/:" + $0 }.joined() + "/:"
        let volume = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return (dir, url.lastPathComponent, volume)
    }

    public static func export(_ tracks: [ExportTrack], playlistName: String = "Keens In Key", notation: KeyNotation = .openKey) -> String {
        export(tracks, playlists: [ExportPlaylist(name: playlistName, trackIndexes: Array(0..<tracks.count))], notation: notation)
    }

    static func playlistNode(_ p: ExportPlaylist, keys: [String]) -> String {
        if p.isFolder {
            var out = "<NODE TYPE=\"FOLDER\" NAME=\"\(esc(p.name))\"><SUBNODES COUNT=\"\(p.children.count)\">"
            for c in p.children { out += playlistNode(c, keys: keys) }
            return out + "</SUBNODES></NODE>"
        }
        var out = "<NODE TYPE=\"PLAYLIST\" NAME=\"\(esc(p.name))\"><PLAYLIST ENTRIES=\"\(p.trackIndexes.count)\" TYPE=\"LIST\" UUID=\"\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))\">"
        for i in p.trackIndexes where i < keys.count {
            out += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(esc(keys[i]))\"></PRIMARYKEY></ENTRY>"
        }
        return out + "</PLAYLIST></NODE>"
    }

    /// Traktor collection with an arbitrary playlist / folder tree.
    public static func export(_ tracks: [ExportTrack], playlists: [ExportPlaylist], notation: KeyNotation = .openKey) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy/M/d"
        let today = df.string(from: Date())
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<NML VERSION=\"19\"><HEAD COMPANY=\"www.native-instruments.com\" PROGRAM=\"Traktor\"></HEAD>\n"
        out += "<MUSICFOLDERS></MUSICFOLDERS>\n"
        out += "<COLLECTION ENTRIES=\"\(tracks.count)\">\n"
        var keys: [String] = []
        for t in tracks {
            let loc = location(t.url)
            keys.append(loc.volume + loc.dir + loc.file)
            let r = t.result
            out += "<ENTRY MODIFIED_DATE=\"\(today)\" MODIFIED_TIME=\"0\" TITLE=\"\(esc(t.title))\" ARTIST=\"\(esc(t.artist))\">"
            out += "<LOCATION DIR=\"\(esc(loc.dir))\" FILE=\"\(esc(loc.file))\" VOLUME=\"\(esc(loc.volume))\" VOLUMEID=\"\(esc(loc.volume))\"></LOCATION>"
            out += "<ALBUM TITLE=\"\(esc(t.album))\"></ALBUM>"
            var info = "<INFO BITRATE=\"0\" GENRE=\"\(esc(t.genre))\" IMPORT_DATE=\"\(today)\" FILESIZE=\"\(t.fileSize / 1024)\""
            if let r {
                info += " PLAYTIME=\"\(Int(r.duration.rounded()))\" PLAYTIME_FLOAT=\"\(String(format: "%.6f", r.duration))\""
                info += " KEY=\"\(esc(r.key.key.formatted(notation)))\" RANKING=\"\(r.energy * 51)\""
                info += " COMMENT=\"\(esc("\(r.key.key.formatted(notation)) - Energy \(r.energy)"))\""
            }
            info += "></INFO>"
            out += info
            if let r, r.tempo.bpm > 0 {
                out += "<TEMPO BPM=\"\(String(format: "%.6f", r.tempo.bpm))\" BPM_QUALITY=\"100.000000\"></TEMPO>"
                out += "<MUSICAL_KEY VALUE=\"\(musicalKeyValue(r.key.key))\"></MUSICAL_KEY>"
                if !r.tempo.beats.isEmpty {
                    let ms = r.tempo.firstDownbeat * 1000
                    out += "<CUE_V2 NAME=\"Beat Marker\" DISPL_ORDER=\"0\" TYPE=\"4\" START=\"\(String(format: "%.6f", ms))\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"-1\"><GRID BPM=\"\(String(format: "%.6f", r.tempo.bpm))\"></GRID></CUE_V2>"
                }
                for (i, cue) in r.cuePoints.prefix(8).enumerated() {
                    out += "<CUE_V2 NAME=\"\(esc(cue.name))\" DISPL_ORDER=\"0\" TYPE=\"0\" START=\"\(String(format: "%.6f", cue.time * 1000))\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"\(i)\"></CUE_V2>"
                }
            }
            out += "</ENTRY>\n"
        }
        out += "</COLLECTION>\n"
        out += "<PLAYLISTS><NODE TYPE=\"FOLDER\" NAME=\"$ROOT\"><SUBNODES COUNT=\"\(playlists.count)\">"
        for p in playlists { out += playlistNode(p, keys: keys) }
        out += "</SUBNODES></NODE></PLAYLISTS>\n</NML>\n"
        return out
    }
}
