import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeensInKeyCore

enum ExportKind { case csv, rekordbox, m3u }

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

    static func exportRows(library: LibraryStore, ids: Set<UUID>) -> [ExportTrack] {
        let tracks = ids.isEmpty ? library.filteredTracks : library.tracks(ids)
        return tracks.map { t in
            ExportTrack(url: t.url, title: t.displayTitle, artist: t.artist, album: t.album, genre: t.genre, fileSize: t.fileSize, result: t.result)
        }
    }

    static func export(_ kind: ExportKind, library: LibraryStore, settings: AppSettings, state: AppState) {
        let rows = exportRows(library: library, ids: state.selection)
        guard !rows.isEmpty else { state.showAlert("Nothing to export", "Add some tracks first."); return }
        let panel = NSSavePanel()
        let text: String
        switch kind {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "keens-in-key.csv"
            text = Exporters.csv(rows, notation: settings.tagOptions.notation)
        case .rekordbox:
            panel.allowedContentTypes = [.xml]
            panel.nameFieldStringValue = "rekordbox.xml"
            text = Exporters.rekordboxXML(rows, notation: settings.tagOptions.notation, appVersion: AppInfo.version)
        case .m3u:
            panel.allowedContentTypes = [UTType("public.m3u-playlist") ?? .plainText]
            panel.nameFieldStringValue = "keens-in-key.m3u8"
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
