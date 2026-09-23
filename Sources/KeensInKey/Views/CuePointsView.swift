import SwiftUI
import KeensInKeyCore

/// Cue point editor with a zoomable waveform.
struct CuePointsView: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(AnalysisController.self) private var analysis
    @State private var zoom: CGFloat = 1
    @State private var selectedCue: UUID?

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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle).font(.system(size: 17, weight: .bold))
                    Text(track.artist.isEmpty ? track.fileName : track.artist).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let r = track.result {
                    KeyBadge(key: r.key.key, notation: settings.displayNotation, size: 14)
                    Text("\(settings.formatBPM(r.tempo.bpm)) BPM").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("Energy \(r.energy)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(energyColor(r.energy))
                }
            }

            ScrollView(.horizontal, showsIndicators: true) {
                WaveformView(track: track, selectedCueId: selectedCue, showAllBeats: zoom >= 4, onSeek: { t in
                    if player.currentTrackId != track.id { player.load(track) }
                    player.seek(to: t)
                }, onSelectCue: { cue in
                    selectedCue = cue.id
                }, onMoveCue: { cue, t in
                    move(cue: cue, to: t, in: track)
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
                Button { addCue(at: player.currentTrackId == track.id ? player.currentTime : 0, in: track) } label: { Label("Add Cue at Playhead", systemImage: "plus.circle") }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
                    .disabled(track.result == nil || (track.result?.cuePoints.count ?? 0) >= 8)
                Button { nudge(in: track, beats: -1) } label: { Label("−1 Beat", systemImage: "arrow.left") }.buttonStyle(ToolbarButtonStyle()).disabled(selectedCue == nil)
                Button { nudge(in: track, beats: 1) } label: { Label("+1 Beat", systemImage: "arrow.right") }.buttonStyle(ToolbarButtonStyle()).disabled(selectedCue == nil)
                Button { snapAll(in: track) } label: { Label("Quantize All", systemImage: "square.grid.3x3") }.buttonStyle(ToolbarButtonStyle()).disabled(track.result == nil)
                Picker("Grid", selection: $settings.quantize) {
                    ForEach(QuantizeMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .frame(width: 170)
                Button(role: .destructive) { deleteSelected(in: track) } label: { Label("Delete", systemImage: "trash") }.buttonStyle(ToolbarButtonStyle(destructive: true)).disabled(selectedCue == nil)
                Spacer()
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
                        TextField("Name", text: Binding(get: { c.name }, set: { newName in rename(cue: c, to: newName, in: track) }))
                            .textFieldStyle(.plain)
                    }.width(min: 120, ideal: 180)
                    TableColumn("Type") { c in
                        Picker("", selection: Binding(get: { c.kind }, set: { k in setKind(cue: c, kind: k, in: track) })) {
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
            }
        }
        .padding(16)
    }

    @State private var waveWidth: CGFloat = 900

    private func modify(_ track: Track, _ f: (inout [CuePoint]) -> Void) {
        library.update(track.id) { t in
            guard var r = t.result else { return }
            f(&r.cuePoints)
            r.cuePoints.sort { $0.time < $1.time }
            for i in r.cuePoints.indices { r.cuePoints[i].slot = i + 1 }
            t.result = r
        }
    }

    private func quantized(_ time: Double, _ r: AnalysisResult) -> (Double, Int?) {
        let q = StructureAnalyzer.quantize(time: time, beats: r.tempo.beats, downbeatPhase: r.tempo.downbeatPhase, mode: settings.quantize)
        let bar = q.bar ?? StructureAnalyzer.barNumber(for: q.time, beats: r.tempo.beats, downbeatPhase: r.tempo.downbeatPhase)
        return (q.time, bar)
    }

    private func addCue(at time: Double, in track: Track) {
        guard let r = track.result else { return }
        let (t, bar) = quantized(time, r)
        let cue = CuePoint(slot: r.cuePoints.count + 1, name: "Cue \(r.cuePoints.count + 1)", kind: .custom, time: t, bar: bar, energy: r.energy)
        modify(track) { $0.append(cue) }
        selectedCue = cue.id
    }

    private func move(cue: CuePoint, to time: Double, in track: Track) {
        guard let r = track.result else { return }
        let (t, bar) = quantized(time, r)
        modify(track) { cues in
            if let i = cues.firstIndex(where: { $0.id == cue.id }) { cues[i].time = t; cues[i].bar = bar }
        }
    }

    private func nudge(in track: Track, beats: Int) {
        guard let r = track.result, let id = selectedCue, let cue = r.cuePoints.first(where: { $0.id == id }), !r.tempo.beats.isEmpty else { return }
        let bs = r.tempo.beats
        var idx = bs.indices.min(by: { abs(bs[$0] - cue.time) < abs(bs[$1] - cue.time) }) ?? 0
        idx = max(0, min(bs.count - 1, idx + beats))
        let t = bs[idx]
        let bar = StructureAnalyzer.barNumber(for: t, beats: bs, downbeatPhase: r.tempo.downbeatPhase)
        modify(track) { cues in
            if let i = cues.firstIndex(where: { $0.id == id }) { cues[i].time = t; cues[i].bar = bar }
        }
    }

    private func snapAll(in track: Track) {
        guard let r = track.result else { return }
        modify(track) { cues in
            for i in cues.indices {
                let (t, bar) = quantized(cues[i].time, r)
                cues[i].time = t; cues[i].bar = bar
            }
        }
    }

    private func deleteSelected(in track: Track) {
        guard let id = selectedCue else { return }
        modify(track) { $0.removeAll { $0.id == id } }
        selectedCue = nil
    }

    private func rename(cue: CuePoint, to name: String, in track: Track) {
        modify(track) { cues in if let i = cues.firstIndex(where: { $0.id == cue.id }) { cues[i].name = name } }
    }

    private func setKind(cue: CuePoint, kind: CueKind, in track: Track) {
        modify(track) { cues in
            if let i = cues.firstIndex(where: { $0.id == cue.id }) {
                let wasDefault = cues[i].name == cues[i].kind.defaultName || cues[i].name.hasPrefix(cues[i].kind.defaultName + " ")
                cues[i].kind = kind
                if wasDefault { cues[i].name = kind.defaultName }
            }
        }
    }
}
