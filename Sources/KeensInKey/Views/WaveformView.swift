import SwiftUI
import KeensInKeyCore

/// Waveform overview with beat grid, cue markers and playhead.
struct WaveformView: View {
    let track: Track
    var selectedCueId: UUID? = nil
    var showAllBeats = false
    var onSeek: (Double) -> Void
    var onSelectCue: ((CuePoint) -> Void)? = nil
    var onMoveCue: ((CuePoint, Double) -> Void)? = nil

    @Environment(Player.self) private var player
    @State private var draggingCue: CuePoint?

    private var duration: Double { max(0.001, track.result?.duration ?? track.duration ?? 1) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = time(at: value.location.x, width: width)
                        if draggingCue == nil, value.translation == .zero, let cue = cue(near: value.startLocation, width: width) {
                            draggingCue = cue
                            onSelectCue?(cue)
                        }
                        if let c = draggingCue, onMoveCue != nil {
                            onMoveCue?(c, t)
                        }
                    }
                    .onEnded { value in
                        if draggingCue == nil {
                            onSeek(time(at: value.location.x, width: width))
                        }
                        draggingCue = nil
                    }
            )
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(1, width)))) * duration
    }

    private func cue(near point: CGPoint, width: CGFloat) -> CuePoint? {
        guard let cues = track.result?.cuePoints, point.y < 22 else { return nil }
        return cues.min(by: { abs(x(for: $0.time, width: width) - point.x) < abs(x(for: $1.time, width: width) - point.x) })
            .flatMap { abs(x(for: $0.time, width: width) - point.x) < 40 ? $0 : nil }
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat { CGFloat(t / duration) * width }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
        let labelBand: CGFloat = 20
        let waveTop = labelBand
        let waveH = h - labelBand
        let mid = waveTop + waveH / 2
        let playX = player.currentTrackId == track.id ? x(for: player.currentTime, width: w) : 0

        // Waveform bars.
        if let wf = track.result?.waveform, !wf.isEmpty {
            let count = wf.count
            let barW = max(1, w / CGFloat(count))
            var played = Path(), rest = Path()
            let step = max(1, Int(CGFloat(count) / w))
            var i = 0
            while i < count {
                var peak: UInt8 = 0
                for j in i..<min(count, i + step) { peak = max(peak, wf[j]) }
                let x = CGFloat(i) / CGFloat(count) * w
                let bh = max(1, CGFloat(peak) / 255 * (waveH / 2 - 3))
                let r = CGRect(x: x, y: mid - bh, width: max(1, barW * CGFloat(step) - 0.5), height: bh * 2)
                if x < playX { played.addRect(r) } else { rest.addRect(r) }
                i += step
            }
            ctx.fill(rest, with: .color(Theme.waveformDim))
            ctx.fill(played, with: .color(Theme.waveform))
        } else {
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w, y: mid)) }, with: .color(Theme.border), lineWidth: 1)
            let text = Text(track.status == .analyzing ? "Analyzing… \(track.stage)" : "Not analyzed yet").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            ctx.draw(text, at: CGPoint(x: w / 2, y: mid))
        }

        // Beat grid.
        if let tempo = track.result?.tempo, !tempo.beats.isEmpty {
            let phase = min(tempo.downbeatPhase, tempo.beats.count - 1)
            let pxPerBeat = w / CGFloat(max(1, tempo.beats.count))
            var beatPath = Path(), barPath = Path()
            for (i, b) in tempo.beats.enumerated() {
                let bx = x(for: b, width: w)
                let isDownbeat = (i - phase) % 4 == 0 && i >= phase
                if isDownbeat {
                    if pxPerBeat * 4 >= 3 { barPath.move(to: CGPoint(x: bx, y: waveTop)); barPath.addLine(to: CGPoint(x: bx, y: h)) }
                } else if showAllBeats || pxPerBeat >= 5 {
                    beatPath.move(to: CGPoint(x: bx, y: mid - waveH * 0.18)); beatPath.addLine(to: CGPoint(x: bx, y: mid + waveH * 0.18))
                }
            }
            ctx.stroke(beatPath, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
            ctx.stroke(barPath, with: .color(Color.white.opacity(0.16)), lineWidth: 1)
        }

        // Cue markers.
        if let cues = track.result?.cuePoints {
            for cue in cues {
                let cx = x(for: cue.time, width: w)
                let color = Color(hex: cue.kind.colorHex)
                let selected = cue.id == selectedCueId
                var line = Path()
                line.move(to: CGPoint(x: cx, y: 0)); line.addLine(to: CGPoint(x: cx, y: h))
                ctx.stroke(line, with: .color(color.opacity(selected ? 1 : 0.8)), lineWidth: selected ? 2 : 1.2)
                let label = Text("\(cue.slot) \(cue.name)").font(.system(size: 9.5, weight: .bold)).foregroundColor(.black.opacity(0.85))
                let resolved = ctx.resolve(label)
                let ts = resolved.measure(in: CGSize(width: 200, height: 20))
                let box = CGRect(x: cx, y: 2, width: ts.width + 8, height: 15)
                ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(color.opacity(selected ? 1 : 0.9)))
                ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }
        }

        // Playhead.
        if player.currentTrackId == track.id {
            var ph = Path()
            ph.move(to: CGPoint(x: playX, y: 0)); ph.addLine(to: CGPoint(x: playX, y: h))
            ctx.stroke(ph, with: .color(.white), lineWidth: 1.5)
        }
    }
}

/// Transport controls under a waveform.
struct TransportBar: View {
    let track: Track
    @Environment(Player.self) private var player
    var extra: AnyView? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if player.currentTrackId == track.id { player.toggle() } else { player.load(track, autoplay: true) }
            } label: {
                Image(systemName: player.currentTrackId == track.id && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(ToolbarButtonStyle(prominent: true))
            Button { player.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 20, height: 26) }
                .buttonStyle(ToolbarButtonStyle())
            Text("\((player.currentTrackId == track.id ? player.currentTime : 0).timeStringMillis) / \((track.result?.duration ?? track.duration ?? 0).timeString)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            if let cues = track.result?.cuePoints, !cues.isEmpty {
                Divider().frame(height: 18)
                ForEach(cues.prefix(8)) { cue in
                    Button {
                        if player.currentTrackId != track.id { player.load(track) }
                        player.seek(to: cue.time)
                        if !player.isPlaying { player.play() }
                    } label: {
                        Text("\(cue.slot)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(width: 24, height: 22)
                            .background(Color(hex: cue.kind.colorHex), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("\(cue.name) · \(cue.time.timeStringMillis)")
                }
            }
            if let extra { extra }
            Spacer()
        }
    }
}
