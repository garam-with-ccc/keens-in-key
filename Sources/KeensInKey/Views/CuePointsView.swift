import SwiftUI
import KeensInKeyCore

/// Cue point editor with a zoomable waveform, beat-grid tools and manual corrections.
struct CuePointsView: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(AnalysisController.self) private var analysis
    @State private var zoom: CGFloat = 1
    @State private var selectedCue: UUID?
    @State private var waveWidth: CGFloat = 900

    var body: some View {
        if let id = state.primarySelection ?? library.tracks.first(where: { $0.result != nil })?.id, let track = library.track(id) {
            editor(for: track)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "flag.2.crossed").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                Text("Select an analyzed track to edit its cue points").font(.system(size: 14, weight: .semibold))
                Text("Cue points are detected on section changes and quantized to the beat grid.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func editor(for track: Track) -> some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle).font(.system(size: 17, weight: .bold))
                    Text(track.artist.isEmpty ? track.fileName : track.artist).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let r = track.result {
                    Menu {
                        ForEach(1...12, id: \.self) { n in
                            let minor = MusicalKey.fromCamelot(number: n, mode: .minor), major = MusicalKey.fromCamelot(number: n, mode: .major)
                            Button("\(minor.camelot)  \(minor.traditional)") { TrackEdits.setKey(minor, ids: [track.id], library: library) }
                            Button("\(major.camelot)  \(major.traditional)") { TrackEdits.setKey(major, ids: [track.id], library: library) }
                        }
                    } label: {
                        KeyBadge(key: r.key.key, notation: settings.displayNotation, size: 14)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Override the detected key")
                    HStack(spacing: 4) {
                        Text("\(settings.formatBPM(r.tempo.bpm)) BPM").font(.system(size: 13, weight: .semibold, design: .rounded))
                        Button("½") { TrackEdits.scaleTempo(0.5, ids: [track.id], library: library) }.buttonStyle(ToolbarButtonStyle()).help("Halve BPM")
                        Button("×2") { TrackEdits.scaleTempo(2, ids: [track.id], library: library) }.buttonStyle(ToolbarButtonStyle()).help("Double BPM")
                    }
                    Text("Energy \(r.energy)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(energyColor(r.energy))
                }
            }

            ScrollView(.horizontal, showsIndicators: true) {
                WaveformView(track: track, selectedCueId: selectedCue, showAllBeats: zoom >= 4, showEnergy: true, onSeek: { t in
                    if player.currentTrackId != track.id { player.load(track) }
                    player.seek(to: t)
                }, onSelectCue: { cue in
                    selectedCue = cue.id
                }, onMoveCue: { cue, t in
                    modify(track) { CueEditing.move(cue.id, to: t, in: &$0, mode: settings.quantize) }
                })
                .frame(width: max(600, waveWidth * zoom), height: 180)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .background(GeometryReader { g in Color.clear.onAppear { waveWidth = g.size.width }.onChange(of: g.size.width) { _, w in waveWidth = w } })

            HStack(spacing: 10) {
                TransportBar(track: track)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.textSecondary)
                    Slider(value: $zoom, in: 1...16).frame(width: 120)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button { addCue(in: track) } label: { Label("Add Cue at Playhead", systemImage: "plus.circle") }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
                    .disabled(track.result == nil || (track.result?.cuePoints.count ?? 0) >= 8)
                Button { nudge(in: track, beats: -1) } label: { Label("−1 Beat", systemImage: "arrow.left") }.buttonStyle(ToolbarButtonStyle()).disabled(selectedCue == nil)
                Button { nudge(in: track, beats: 1) } label: { Label("+1 Beat", systemImage: "arrow.right") }.buttonStyle(ToolbarButtonStyle()).disabled(selectedCue == nil)
                Button { modify(track) { CueEditing.snapAll(in: &$0, mode: settings.quantize) } } label: { Label("Quantize All", systemImage: "square.grid.3x3") }
                    .buttonStyle(ToolbarButtonStyle()).disabled(track.result == nil)
                Picker("Grid", selection: $settings.quantize) {
                    ForEach(QuantizeMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .frame(width: 170)
                Button(role: .destructive) { deleteSelected(in: track) } label: { Label("Delete", systemImage: "trash") }.buttonStyle(ToolbarButtonStyle(destructive: true)).disabled(selectedCue == nil)
                Spacer()
                HStack(spacing: 4) {
                    Text("Downbeat").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Button { TrackEdits.shiftDownbeat(-1, id: track.id, library: library) } label: { Image(systemName: "chevron.left") }.buttonStyle(ToolbarButtonStyle()).help("Move the downbeat one beat earlier")
                    Button { TrackEdits.shiftDownbeat(1, id: track.id, library: library) } label: { Image(systemName: "chevron.right") }.buttonStyle(ToolbarButtonStyle()).help("Move the downbeat one beat later")
                }
                .disabled(track.result == nil)
                Button { analysis.enqueue([track.id], force: true) } label: { Label("Re-detect", systemImage: "arrow.clockwise") }.buttonStyle(ToolbarButtonStyle())
            }

            if let r = track.result {
                Table(r.cuePoints, selection: $selectedCue) {
                    TableColumn("#") { c in
                        Text("\(c.slot)").font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.85)).frame(width: 20, height: 18)
                            .background(Color(hex: c.kind.colorHex), in: RoundedRectangle(cornerRadius: 4))
                    }.width(36)
                    TableColumn("Name") { c in
                        TextField("Name", text: Binding(get: { c.name }, set: { newName in modify(track) { CueEditing.rename(c.id, to: newName, in: &$0) } }))
                            .textFieldStyle(.plain)
                    }.width(min: 120, ideal: 180)
                    TableColumn("Type") { c in
                        Picker("", selection: Binding(get: { c.kind }, set: { k in modify(track) { CueEditing.setKind(c.id, k, in: &$0) } })) {
                            ForEach(CueKind.allCases, id: \.self) { k in Text(k.defaultName).tag(k) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }.width(110)
                    TableColumn("Time") { c in Text(c.time.timeStringMillis).monospacedDigit() }.width(80)
                    TableColumn("Bar") { c in Text(c.bar.map { "Bar \($0)" } ?? "—").foregroundStyle(Theme.textSecondary) }.width(70)
                    TableColumn("Energy") { c in
                        HStack(spacing: 6) { Text("\(c.energy)").monospacedDigit(); EnergyBar(level: c.energy, width: 50, height: 6) }
                    }.width(90)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                Text("Keys 1–8 jump to a cue · Space plays / pauses · drag a flag on the waveform to move it (snaps to the grid)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .background(HotkeyCatcher(track: track))
    }

    private func modify(_ track: Track, _ f: (inout AnalysisResult) -> Void) {
        library.update(track.id) { t in
            guard var r = t.result else { return }
            f(&r)
            t.result = r
            t.tagsWrittenAt = nil
        }
    }

    private func addCue(in track: Track) {
        let time = player.currentTrackId == track.id ? player.currentTime : 0
        var newId: UUID?
        modify(track) { r in newId = CueEditing.add(at: time, to: &r, mode: settings.quantize, maxCues: settings.analysis.cueCount)?.id }
        if let newId { selectedCue = newId }
    }

    private func nudge(in track: Track, beats: Int) {
        guard let id = selectedCue else { return }
        modify(track) { CueEditing.nudge(id, beats: beats, in: &$0) }
    }

    private func deleteSelected(in track: Track) {
        guard let id = selectedCue else { return }
        modify(track) { CueEditing.delete(id, in: &$0) }
        selectedCue = nil
    }
}

/// Invisible view providing number-key shortcuts (1–8 jump to hot cues) while the cue page is shown.
private struct HotkeyCatcher: View {
    let track: Track
    @Environment(Player.self) private var player

    var body: some View {
        ZStack {
            ForEach(1...8, id: \.self) { n in
                Button("") {
                    guard let cue = track.result?.cuePoints.first(where: { $0.slot == n }) else { return }
                    if player.currentTrackId != track.id { player.load(track) }
                    player.seek(to: cue.time)
                    if !player.isPlaying { player.play() }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
