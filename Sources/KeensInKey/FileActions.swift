import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeensInKeyCore

enum ExportKind { case csv, rekordbox, traktor, m3u }

@MainActor
enum FileActions {
    static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, UTType("org.xiph.flac") ?? .audio]

    static func addFiles(library: LibraryStore, settings: AppSettings, analysis: AnalysisController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = audioTypes
        panel.message = "Choose audio files or folders to analyze"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            let ids = library.add(urls: panel.urls)
            if settings.autoAnalyzeOnAdd { analysis.enqueue(ids) }
        }
    }

    static func addFolder(library: LibraryStore, settings: AppSettings, analysis: AnalysisController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose folders to scan for music"
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK {
            let ids = library.add(urls: panel.urls)
            if settings.autoAnalyzeOnAdd { analysis.enqueue(ids) }
        }
    }

    static func exportTrack(_ t: Track) -> ExportTrack {
        ExportTrack(url: t.url, title: t.displayTitle, artist: t.artist, album: t.album, genre: t.genre, fileSize: t.fileSize, result: t.result)
    }

    /// Rows for the current context: the selection, else the selected playlist (filtered), else the filtered library.
    static func exportRows(library: LibraryStore, state: AppState) -> (rows: [ExportTrack], name: String) {
        if !state.selection.isEmpty { return (library.tracks(state.selection).map(exportTrack), "Selection") }
        if let sel = state.playlistSelection, let node = library.node(sel) {
            return (library.filtered(library.tracks(in: sel)).map(exportTrack), node.name)
        }
        return (library.filteredTracks.map(exportTrack), "Keens In Key")
    }

    static func safeName(_ s: String) -> String { TagService.sanitizeFileName(s) }

    static func export(_ kind: ExportKind, library: LibraryStore, settings: AppSettings, state: AppState) {
        let (rows, name) = exportRows(library: library, state: state)
        guard !rows.isEmpty else { state.showAlert("Nothing to export", "Add some tracks first."); return }
        let panel = NSSavePanel()
        let text: String
        switch kind {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "\(safeName(name)).csv"
            text = Exporters.csv(rows, notation: settings.tagOptions.notation)
        case .rekordbox:
            panel.allowedContentTypes = [.xml]
            panel.nameFieldStringValue = "rekordbox.xml"
            text = Exporters.rekordboxXML(rows, playlistName: name, notation: settings.tagOptions.notation, appVersion: AppInfo.version)
        case .traktor:
            panel.allowedContentTypes = [UTType(filenameExtension: "nml") ?? .xml]
            panel.nameFieldStringValue = "\(safeName(name)).nml"
            text = TraktorNML.export(rows, playlistName: name, notation: settings.tagOptions.notation == .camelot ? .openKey : settings.tagOptions.notation)
        case .m3u:
            panel.allowedContentTypes = [UTType("public.m3u-playlist") ?? .plainText]
            panel.nameFieldStringValue = "\(safeName(name)).m3u8"
            text = Exporters.m3u(rows)
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                state.showAlert("Export complete", "Exported \(rows.count) track\(rows.count == 1 ? "" : "s") to \(url.lastPathComponent).")
            } catch {
                state.showAlert("Export failed", error.localizedDescription)
            }
        }
    }

    /// Exports every collection with its nested playlists as one rekordbox XML / Traktor NML file.
    static func exportCollections(_ kind: ExportKind, library: LibraryStore, settings: AppSettings, state: AppState) {
        // Collect every track referenced by any playlist, then build the tree with indexes into that list.
        var index: [UUID: Int] = [:]
        var rows: [ExportTrack] = []
        func idx(_ id: UUID) -> Int? {
            if let i = index[id] { return i }
            guard let t = library.track(id) else { return nil }
            index[id] = rows.count
            rows.append(exportTrack(t))
            return rows.count - 1
        }
        func build(_ node: PlaylistNode) -> ExportPlaylist {
            switch node.kind {
            case .folder:
                return ExportPlaylist(name: node.displayName, isFolder: true, children: node.children.map(build))
            case .playlist, .smart:
                let ids = library.tracks(in: node.id).map(\.id)
                var p = ExportPlaylist(name: node.displayName, trackIndexes: ids.compactMap(idx))
                if !node.children.isEmpty {
                    // Nested playlists become a folder holding the playlist itself and its children.
                    p = ExportPlaylist(name: node.displayName, isFolder: true, children: [ExportPlaylist(name: node.displayName, trackIndexes: p.trackIndexes)] + node.children.map(build))
                }
                return p
            }
        }
        let tree = library.collections.map(build)
        guard !rows.isEmpty else { state.showAlert("Nothing to export", "Your playlists do not contain any tracks yet."); return }
        let panel = NSSavePanel()
        let text: String
        switch kind {
        case .rekordbox:
            panel.allowedContentTypes = [.xml]
            panel.nameFieldStringValue = "rekordbox.xml"
            text = Exporters.rekordboxXML(rows, playlists: tree, notation: settings.tagOptions.notation, appVersion: AppInfo.version)
        default:
            panel.allowedContentTypes = [UTType(filenameExtension: "nml") ?? .xml]
            panel.nameFieldStringValue = "collection.nml"
            text = TraktorNML.export(rows, playlists: tree, notation: settings.tagOptions.notation == .camelot ? .openKey : settings.tagOptions.notation)
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                let count = PlaylistTree.allNodes(library.collections).filter { $0.kind != .folder }.count
                state.showAlert("Export complete", "Exported \(count) playlist\(count == 1 ? "" : "s") with \(rows.count) track\(rows.count == 1 ? "" : "s") to \(url.lastPathComponent).")
            } catch {
                state.showAlert("Export failed", error.localizedDescription)
            }
        }
    }

    static func writeTags(ids: [UUID], analysis: AnalysisController, state: AppState) {
        guard let writer = analysis.tagWriter else { return }
        Task { @MainActor in
            let (written, errors) = await writer.write(ids: ids)
            if errors.isEmpty {
                state.showAlert("Tags written", "Updated \(written) file\(written == 1 ? "" : "s").")
            } else {
                state.showAlert("Tags written with errors", "Updated \(written) file(s).\n\n" + errors.prefix(6).joined(separator: "\n"))
            }
        }
    }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
