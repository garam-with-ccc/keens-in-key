import SwiftUI
import KeensInKeyCore

/// Bottom panel on the Analyze page for the selected track.
struct DetailPanel: View {
    let track: Track
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisController.self) private var analysis

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(track.artist.isEmpty ? track.fileName : track.artist).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    if let r = track.result {
                        HStack(spacing: 6) {
                            Text("Compatible:").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            ForEach(r.key.key.compatibleKeys.dropFirst(), id: \.self) { k in
                                KeyBadge(key: k, notation: settings.displayNotation, size: 10)
                            }
                            Text("boost").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                            KeyBadge(key: r.key.key.energyBoostKey, notation: settings.displayNotation, size: 10)
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(width: 300, alignment: .leading)

                if let r = track.result {
                    HStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("KEY").font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textSecondary)
                            HStack(spacing: 6) {
                                KeyBadge(key: r.key.key, notation: settings.displayNotation, size: 17)
                                Text(r.key.key.longName).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            Text("confidence \(Int((r.key.confidence * 100).rounded()))%").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                        }
                        StatPill(label: "BPM", value: settings.formatBPM(r.tempo.bpm))
                        VStack(alignment: .leading, spacing: 4) {
                            StatPill(label: "Energy", value: "\(r.energy)", color: energyColor(r.energy))
                            EnergyBar(level: r.energy, width: 70, height: 7)
                        }
                        StatPill(label: "Loudness", value: String(format: "%.1f dB", r.loudnessDb))
                        StatPill(label: "Cues", value: "\(r.cuePoints.count)")
                    }
                } else {
                    Text(track.status == .failed ? "Analysis failed: \(track.errorMessage ?? "")" : (track.status == .analyzing ? "Analyzing… \(track.stage)" : "Not analyzed yet"))
                        .font(.system(size: 12)).foregroundStyle(track.status == .failed ? Theme.danger : Theme.textSecondary)
                }
                Spacer()
                Button { state.page = .cues } label: { Label("Edit Cues", systemImage: "flag") }.buttonStyle(ToolbarButtonStyle())
                Button { state.wheelKey = track.key; state.page = .wheel } label: { Label("Wheel", systemImage: "circle.hexagongrid") }
                    .buttonStyle(ToolbarButtonStyle()).disabled(track.key == nil)
            }
            WaveformView(track: track) { t in
                if player.currentTrackId != track.id { player.load(track) }
                player.seek(to: t)
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            TransportBar(track: track)
        }
        .padding(14)
        .background(Theme.panel)
        .frame(height: 240)
    }
}
