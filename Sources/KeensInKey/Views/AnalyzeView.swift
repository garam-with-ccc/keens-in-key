import SwiftUI
import AppKit
import KeensInKeyCore

struct AnalyzeView: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisController.self) private var analysis
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            AnalyzeToolbar()
            Rectangle().fill(Theme.border).frame(height: 1)
            if library.tracks.isEmpty {
                DropZone()
            } else {
                TrackTable()
            }
            if let id = state.primarySelection, let track = library.track(id) {
                Rectangle().fill(Theme.border).frame(height: 1)
                DetailPanel(track: track)
            }
        }
    }
}

struct AnalyzeToolbar: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisController.self) private var analysis

    var body: some View {
        @Bindable var library = library
        HStack(spacing: 8) {
            Button { FileActions.addFiles(library: library, settings: settings, analysis: analysis) } label: {
                Label("Add Files", systemImage: "plus")
            }
            .buttonStyle(ToolbarButtonStyle(prominent: true))
            Button { FileActions.addFolder(library: library, settings: settings, analysis: analysis) } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(ToolbarButtonStyle())

            Divider().frame(height: 18)

            if analysis.isRunning {
                Button { analysis.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(ToolbarButtonStyle(destructive: true))
            } else {
                Button {
                    let ids = state.selection.isEmpty ? library.tracks.map(\.id) : Array(state.selection)
                    analysis.enqueue(ids, force: !state.selection.isEmpty)
                } label: {
                    Label(state.selection.isEmpty ? "Analyze All" : "Analyze Selected", systemImage: "waveform")
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(library.tracks.isEmpty)
            }

            Button {
                let ids = state.selection.isEmpty ? library.tracks.filter { $0.result != nil }.map(\.id) : Array(state.selection)
                FileActions.writeTags(ids: ids, analysis: analysis, state: state)
            } label: {
                Label(state.selection.isEmpty ? "Write Tags" : "Write Tags (\(state.selection.count))", systemImage: "tag")
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(library.tracks.allSatisfy { $0.result == nil })

            Menu {
                Button("CSV…") { FileActions.export(.csv, library: library, settings: settings, state: state) }
                Button("rekordbox XML…") { FileActions.export(.rekordbox, library: library, settings: settings, state: state) }
                Button("M3U Playlist…") { FileActions.export(.m3u, library: library, settings: settings, state: state) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(ToolbarButtonStyle())
            .disabled(library.tracks.isEmpty)

            Spacer()

            if analysis.isRunning {
                HStack(spacing: 8) {
                    ProgressView(value: Double(analysis.completed), total: Double(max(1, analysis.total)))
                        .frame(width: 120)
                        .tint(Theme.accent)
                    Text("\(analysis.completed) / \(analysis.total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
            } else if !analysis.statusMessage.isEmpty {
                Text(analysis.statusMessage).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }

            if library.keyFilter != nil {
                Button {
                    library.keyFilter = nil
                } label: {
                    HStack(spacing: 4) {
                        Text("Compatible with")
                        KeyBadge(key: library.keyFilter, size: 10)
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .buttonStyle(ToolbarButtonStyle())
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).font(.system(size: 11))
                TextField("Search", text: $library.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 150)
                if !library.searchText.isEmpty {
                    Button { library.searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

struct DropZone: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisController.self) private var analysis

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Drag & drop your music here")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("MP3, M4A/AAC, WAV, AIFF, FLAC. Folders are scanned recursively.\nKeens In Key detects the key, BPM, energy level and cue points of every track.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Button { FileActions.addFiles(library: library, settings: settings, analysis: analysis) } label: {
                Label("Choose Files…", systemImage: "folder")
            }
            .buttonStyle(ToolbarButtonStyle(prominent: true))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(Theme.border)
                .padding(24)
        )
    }
}

struct TrackTable: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisController.self) private var analysis
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var state = state
        let rows = library.filteredTracks.sorted(using: state.sortOrder)
        Table(rows, selection: $state.selection, sortOrder: $state.sortOrder) {
            Group {
                TableColumn("", value: \.statusSortValue) { t in StatusCell(track: t).frame(maxWidth: .infinity) }
                    .width(26)
                TableColumn("Artist", value: \.artist) { t in ArtistCell(track: t) }
                    .width(min: 90, ideal: 160)
                TableColumn("Song Name", value: \.displayTitle) { t in Text(t.displayTitle).lineLimit(1) }
                    .width(min: 120, ideal: 240)
                TableColumn("Key", value: \.keySortValue) { t in KeyCell(track: t, notation: settings.displayNotation) }
                    .width(min: 84, ideal: 100)
                TableColumn("BPM", value: \.bpmSortValue) { t in BPMCell(track: t, decimals: settings.bpmDisplayDecimals) }
                    .width(min: 52, ideal: 64)
                TableColumn("Energy", value: \.energySortValue) { t in EnergyCell(track: t) }
                    .width(min: 80, ideal: 92)
            }
            Group {
                TableColumn("Cues", value: \.cueCountValue) { t in CueCountCell(track: t) }
                    .width(40)
                TableColumn("Time", value: \.durationSortValue) { t in DurationCell(track: t) }
                    .width(48)
                TableColumn("Tags", value: \.tagsSortValue) { t in TagsCell(track: t) }
                    .width(40)
                TableColumn("Format", value: \.format) { t in FormatCell(track: t) }
                    .width(48)
                TableColumn("File", value: \.fileName) { t in PathCell(track: t) }
                    .width(min: 100, ideal: 220)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .contextMenu(forSelectionType: UUID.self) { ids in
            let sel = ids.isEmpty ? state.selection : ids
            Button("Play") { if let id = sel.first, let t = library.track(id) { player.load(t, autoplay: true) } }
            Button("Analyze") { analysis.enqueue(Array(sel), force: true) }
            Button("Write Tags") { FileActions.writeTags(ids: Array(sel), analysis: analysis, state: state) }
            Divider()
            Button("Show Cue Points") { if let id = sel.first { state.selection = [id]; state.page = .cues } }
            Button("Show on Camelot Wheel") { if let id = sel.first, let k = library.track(id)?.key { state.wheelKey = k; state.page = .wheel } }
            Button("Find Compatible Tracks") { if let id = sel.first, let k = library.track(id)?.key { library.keyFilter = k } }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(library.tracks(sel).map(\.url)) }
            Button("Remove from Library") { library.remove(ids: sel); state.selection.subtract(sel) }
        } primaryAction: { ids in
            if let id = ids.first, let t = library.track(id) { player.load(t, autoplay: true) }
        }
    }
}

// MARK: - Table cells (kept small so the type checker stays fast)

private struct ArtistCell: View {
    let track: Track
    var body: some View {
        Text(track.artist).lineLimit(1).foregroundStyle(track.artist.isEmpty ? Theme.textSecondary : Theme.text)
    }
}

private struct KeyCell: View {
    let track: Track
    let notation: KeyNotation
    var body: some View {
        HStack(spacing: 6) {
            KeyBadge(key: track.key, notation: notation, size: 11.5)
            if let k = track.key, notation != .traditional {
                Text(k.traditional).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct BPMCell: View {
    let track: Track
    let decimals: Int
    var body: some View {
        Text(track.bpm.map { String(format: "%.\(decimals)f", $0) } ?? "")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}

private struct EnergyCell: View {
    let track: Track
    var body: some View {
        HStack(spacing: 6) {
            Text(track.energy.map(String.init) ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 16, alignment: .trailing)
            EnergyBar(level: track.energy, width: 54, height: 7)
        }
    }
}

private struct CueCountCell: View {
    let track: Track
    var body: some View {
        Text(track.result.map { String($0.cuePoints.count) } ?? "").foregroundStyle(Theme.textSecondary).monospacedDigit()
    }
}

private struct DurationCell: View {
    let track: Track
    var body: some View {
        let d: Double? = track.result?.duration ?? track.duration
        Text(d.map { $0.timeString } ?? "").foregroundStyle(Theme.textSecondary).monospacedDigit()
    }
}

private struct TagsCell: View {
    let track: Track
    var body: some View {
        if track.tagsWrittenAt != nil {
            Image(systemName: "tag.fill").font(.system(size: 10)).foregroundStyle(Theme.teal).frame(maxWidth: .infinity)
        } else if let k = track.existingTags.initialKey, !k.isEmpty {
            Text(k).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity).help("Existing key tag: \(k)")
        } else {
            Text("")
        }
    }
}

private struct FormatCell: View {
    let track: Track
    var body: some View {
        Text(track.format).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
    }
}

private struct PathCell: View {
    let track: Track
    var body: some View {
        Text(track.path).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textSecondary).font(.system(size: 11))
    }
}
