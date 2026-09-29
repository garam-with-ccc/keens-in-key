import SwiftUI
import AppKit
import KeensInKeyCore

enum Page: String, CaseIterable, Identifiable {
    case analyze, cues, wheel, personalize, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .analyze: return "Analyze"
        case .cues: return "Cue Points"
        case .wheel: return "Camelot Wheel"
        case .personalize: return "Personalize"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .analyze: return "waveform.badge.magnifyingglass"
        case .cues: return "flag.2.crossed"
        case .wheel: return "circle.hexagongrid"
        case .personalize: return "tag"
        case .settings: return "gearshape"
        }
    }
}

/// UI state shared across views.
@Observable
final class AppState {
    var page: Page = .analyze
    var selection = Set<UUID>()
    var sortOrder: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.addedAt)]
    var alertMessage: String?
    var alertTitle = "Keens In Key"
    var wheelKey: MusicalKey?
    /// Selected collection / playlist in the sidebar (nil = whole library).
    var playlistSelection: UUID?
    var showTagPanel = false
    var showTagManager = false
    var showSongInfo = false
    var editingNode: UUID?          // rename / emoji sheet
    var editingSmartRules: UUID?    // smart playlist rule editor
    var newNodeRequest: NewNodeRequest?

    struct NewNodeRequest: Identifiable {
        var id = UUID()
        var kind: PlaylistKind
        var parent: UUID?
    }

    var primarySelection: UUID? { selection.count == 1 ? selection.first : nil }

    func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }
}

@main
struct KeensInKeyApp: App {
    @State private var library = LibraryStore()
    @State private var settings = AppSettings()
    @State private var analysis = AnalysisController()
    @State private var player = Player()
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(settings)
                .environment(analysis)
                .environment(player)
                .environment(state)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    analysis.bind(library: library, settings: settings)
                    analysis.tagWriter = TagWriteCoordinator(library: library, settings: settings)
                    appDelegate.onOpenFiles = { urls in
                        let ids = library.add(urls: urls)
                        if settings.autoAnalyzeOnAdd { analysis.enqueue(ids) }
                    }
                    SnapshotRunner.runIfRequested(library: library, settings: settings, analysis: analysis, state: state, player: player)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            AppCommands(library: library, settings: settings, analysis: analysis, player: player, state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenFiles?(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu bar commands.
struct AppCommands: Commands {
    let library: LibraryStore
    let settings: AppSettings
    let analysis: AnalysisController
    let player: Player
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { FileActions.addFiles(library: library, settings: settings, analysis: analysis) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Folder…") { FileActions.addFolder(library: library, settings: settings, analysis: analysis) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("New Collection…") { state.newNodeRequest = .init(kind: .folder, parent: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Playlist…") { state.newNodeRequest = .init(kind: .playlist, parent: library.collections.first?.id) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Smart Playlist…") { state.newNodeRequest = .init(kind: .smart, parent: library.collections.first?.id) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Export CSV…") { FileActions.export(.csv, library: library, settings: settings, state: state) }
            Button("Export rekordbox XML…") { FileActions.export(.rekordbox, library: library, settings: settings, state: state) }
            Button("Export Traktor NML…") { FileActions.export(.traktor, library: library, settings: settings, state: state) }
            Button("Export M3U Playlist…") { FileActions.export(.m3u, library: library, settings: settings, state: state) }
            Divider()
            Button("Export All Collections as rekordbox XML…") { FileActions.exportCollections(.rekordbox, library: library, settings: settings, state: state) }
            Button("Export All Collections as Traktor NML…") { FileActions.exportCollections(.traktor, library: library, settings: settings, state: state) }
        }
        CommandMenu("Analysis") {
            Button("Analyze All") { analysis.enqueue(library.tracks.map(\.id)) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Analyze Selected") { analysis.enqueue(Array(state.selection), force: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
            Button("Stop Analysis") { analysis.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!analysis.isRunning)
            Divider()
            Button("Write Tags to Selected") { FileActions.writeTags(ids: Array(state.selection), analysis: analysis, state: state) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(state.selection.isEmpty)
            Button("Write Tags to All Analyzed") { FileActions.writeTags(ids: library.tracks.filter { $0.result != nil }.map(\.id), analysis: analysis, state: state) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandMenu("Track") {
            Menu("Add to Playlist") {
                ForEach(library.manualPlaylists, id: \.node.id) { entry in
                    Button(entry.path) { library.add(trackIds: Array(state.selection), to: entry.node.id) }
                }
            }
            .disabled(state.selection.isEmpty || library.manualPlaylists.isEmpty)
            Button("Show Tag Panel") { state.showTagPanel.toggle(); state.page = .analyze }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Menu("Set Key") {
                ForEach(1...12, id: \.self) { n in
                    let minor = MusicalKey.fromCamelot(number: n, mode: .minor), major = MusicalKey.fromCamelot(number: n, mode: .major)
                    Button("\(minor.camelot)  \(minor.traditional)") { TrackEdits.setKey(minor, ids: state.selection, library: library) }
                    Button("\(major.camelot)  \(major.traditional)") { TrackEdits.setKey(major, ids: state.selection, library: library) }
                }
            }
            .disabled(state.selection.isEmpty)
            Button("Double BPM") { TrackEdits.scaleTempo(2, ids: state.selection, library: library) }.disabled(state.selection.isEmpty)
            Button("Halve BPM") { TrackEdits.scaleTempo(0.5, ids: state.selection, library: library) }.disabled(state.selection.isEmpty)
            Divider()
            Button(player.isPlaying ? "Pause" : "Play") {
                if let id = state.primarySelection, let t = library.track(id), player.currentTrackId != id {
                    player.load(t, autoplay: true)
                } else {
                    player.toggle()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Reveal in Finder") {
                let urls = library.tracks(state.selection).map(\.url)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(state.selection.isEmpty)
            Divider()
            Button("Remove from Library") {
                library.remove(ids: state.selection)
                state.selection.removeAll()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(state.selection.isEmpty)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { state.page = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Keens In Key on GitHub") {
                if let url = URL(string: "https://github.com/garam-with-ccc/keens-in-key") { NSWorkspace.shared.open(url) }
            }
        }
    }
}


/// Manual corrections applied to analysed tracks.
@MainActor
enum TrackEdits {
    static func setKey(_ key: MusicalKey, ids: Set<UUID>, library: LibraryStore) {
        for id in ids {
            library.update(id) { t in
                guard var r = t.result else { return }
                CueEditing.setKey(key, in: &r)
                t.result = r
                t.tagsWrittenAt = nil
            }
        }
    }

    static func scaleTempo(_ factor: Double, ids: Set<UUID>, library: LibraryStore) {
        for id in ids {
            library.update(id) { t in
                guard var r = t.result else { return }
                CueEditing.scaleTempo(by: factor, in: &r)
                t.result = r
                t.tagsWrittenAt = nil
            }
        }
    }

    static func shiftDownbeat(_ beats: Int, id: UUID, library: LibraryStore) {
        library.update(id) { t in
            guard var r = t.result else { return }
            CueEditing.shiftDownbeat(by: beats, in: &r)
            t.result = r
        }
    }
}
