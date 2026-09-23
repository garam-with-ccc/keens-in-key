import SwiftUI
import KeensInKeyCore

/// Interactive Camelot wheel.
struct CamelotWheel: View {
    var selected: MusicalKey?
    var highlightCompatible = true
    var onSelect: (MusicalKey) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outerR = size * 0.48, midR = size * 0.34, innerR = size * 0.20
            Canvas { ctx, _ in
                for n in 1...12 {
                    for mode in [Mode.major, Mode.minor] {
                        let key = MusicalKey.fromCamelot(number: n, mode: mode)
                        let r0 = mode == .major ? midR : innerR
                        let r1 = mode == .major ? outerR : midR
                        let path = segmentPath(centre: centre, r0: r0, r1: r1, number: n)
                        var color = key.badgeColor
                        var alpha = 1.0
                        if let sel = selected, highlightCompatible {
                            let rel = sel.relation(to: key)
                            alpha = rel.isCompatible ? 1.0 : (rel == .energyBoost ? 0.7 : 0.28)
                        }
                        if mode == .minor { color = color.opacity(0.92) }
                        ctx.fill(path, with: .color(color.opacity(alpha)))
                        ctx.stroke(path, with: .color(Theme.background), lineWidth: 2)
                        if let sel = selected, sel == key {
                            ctx.stroke(path, with: .color(.white), lineWidth: 3)
                        }
                        let a = angle(for: n)
                        let rr = (r0 + r1) / 2
                        let p = CGPoint(x: centre.x + cos(a) * rr, y: centre.y + sin(a) * rr)
                        let label = Text(key.camelot).font(.system(size: mode == .major ? size * 0.05 : size * 0.042, weight: .heavy, design: .rounded)).foregroundColor(.black.opacity(alpha < 0.5 ? 0.5 : 0.85))
                        ctx.draw(label, at: CGPoint(x: p.x, y: p.y - size * 0.014), anchor: .center)
                        let sub = Text(key.traditional).font(.system(size: size * 0.03, weight: .semibold)).foregroundColor(.black.opacity(alpha < 0.5 ? 0.4 : 0.65))
                        ctx.draw(sub, at: CGPoint(x: p.x, y: p.y + size * 0.03), anchor: .center)
                    }
                }
                // Centre.
                let disc = Path(ellipseIn: CGRect(x: centre.x - innerR + 3, y: centre.y - innerR + 3, width: (innerR - 3) * 2, height: (innerR - 3) * 2))
                ctx.fill(disc, with: .color(Theme.panelRaised))
                if let sel = selected {
                    ctx.draw(Text(sel.camelot).font(.system(size: size * 0.09, weight: .heavy, design: .rounded)).foregroundColor(Theme.text), at: CGPoint(x: centre.x, y: centre.y - size * 0.02), anchor: .center)
                    ctx.draw(Text(sel.longName).font(.system(size: size * 0.035, weight: .medium)).foregroundColor(Theme.textSecondary), at: CGPoint(x: centre.x, y: centre.y + size * 0.05), anchor: .center)
                } else {
                    ctx.draw(Text("Camelot").font(.system(size: size * 0.05, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary), at: centre, anchor: .center)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let dx = location.x - centre.x, dy = location.y - centre.y
                let r = sqrt(dx * dx + dy * dy)
                guard r >= innerR, r <= outerR else { return }
                var theta = atan2(dx, -dy)   // 0 at top, clockwise
                if theta < 0 { theta += 2 * .pi }
                var n = Int(((theta + .pi / 12) / (.pi / 6)).rounded(.down)) % 12
                if n == 0 { n = 12 }
                onSelect(MusicalKey.fromCamelot(number: n, mode: r >= midR ? .major : .minor))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func angle(for n: Int) -> CGFloat {
        // Number 12 at the top, 3 at the right: screen angle measured from +x, clockwise (y down).
        CGFloat(n) * .pi / 6 - .pi / 2
    }

    private func segmentPath(centre: CGPoint, r0: CGFloat, r1: CGFloat, number n: Int) -> Path {
        let a = angle(for: n)
        let start = Angle(radians: Double(a - .pi / 12))
        let end = Angle(radians: Double(a + .pi / 12))
        var p = Path()
        p.addArc(center: centre, radius: r1, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: centre, radius: r0, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct CamelotWheelPage: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player

    private var selectedKey: MusicalKey? {
        state.wheelKey ?? state.primarySelection.flatMap { library.track($0)?.key }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                CamelotWheel(selected: selectedKey) { key in
                    state.wheelKey = key
                }
                .padding(20)
                Text("Click a key to see what mixes with it. Same number = relative major/minor; ±1 = harmonic neighbours; +2 = energy boost.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 30).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.border).frame(width: 1)

            VStack(alignment: .leading, spacing: 12) {
                if let key = selectedKey {
                    HStack(spacing: 10) {
                        KeyBadge(key: key, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.longName).font(.system(size: 16, weight: .bold))
                            Text("Camelot \(key.camelot) · Open Key \(key.openKey) · \(key.traditionalSharps)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button {
                            library.keyFilter = key
                            state.page = .analyze
                        } label: { Label("Filter list", systemImage: "line.3.horizontal.decrease.circle") }.buttonStyle(ToolbarButtonStyle())
                    }
                    SectionHeader(title: "Harmonic mixing rules")
                    VStack(alignment: .leading, spacing: 6) {
                        ruleRow("Perfect match", [key])
                        ruleRow("Harmonic neighbours (±1)", Array(key.compatibleKeys[1...2]))
                        ruleRow("Relative key", [key.relativeKey])
                        ruleRow("Energy boost (+2)", [key.energyBoostKey])
                        ruleRow("Mood change (±3, other letter)", [MusicalKey.fromCamelot(number: (key.camelotNumber + 2) % 12 + 1, mode: key.mode == .major ? .minor : .major), MusicalKey.fromCamelot(number: (key.camelotNumber + 8) % 12 + 1, mode: key.mode == .major ? .minor : .major)])
                    }
                    SectionHeader(title: "Compatible tracks in your library")
                    let matches = library.tracks.filter { $0.key.map { key.relation(to: $0).isCompatible } ?? false }
                        .sorted { (a, b) in
                            let ra = key.relation(to: a.key!), rb = key.relation(to: b.key!)
                            if ra != rb { return order(ra) < order(rb) }
                            return a.displayTitle < b.displayTitle
                        }
                    if matches.isEmpty {
                        Text("No analyzed tracks in compatible keys yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(matches) { t in
                                    HStack(spacing: 8) {
                                        KeyBadge(key: t.key, notation: settings.displayNotation, size: 10.5)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text("\(t.artist.isEmpty ? t.fileName : t.artist) · \(t.bpm.map { settings.formatBPM($0) } ?? "") BPM · Energy \(t.energy ?? 0)").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(key.relation(to: t.key!).label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                                        Button { player.load(t, autoplay: true) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                                    }
                                    .padding(.vertical, 5).padding(.horizontal, 8)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .onTapGesture(count: 2) { player.load(t, autoplay: true) }
                                    .onTapGesture { state.selection = [t.id] }
                                }
                            }
                        }
                    }
                } else {
                    Text("Select a key on the wheel, or select an analyzed track.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    SectionHeader(title: "Your library by key")
                    let counts = Dictionary(grouping: library.tracks.compactMap(\.key), by: { $0 }).mapValues(\.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                        ForEach(MusicalKey.allKeys, id: \.self) { k in
                            Button { state.wheelKey = k } label: {
                                HStack(spacing: 4) { KeyBadge(key: k, size: 10); Text("\(counts[k] ?? 0)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
            }
            .padding(18)
            .frame(width: 420)
        }
    }

    private func order(_ r: HarmonicRelation) -> Int {
        switch r {
        case .same: return 0
        case .relative: return 1
        case .adjacent: return 2
        case .energyBoost: return 3
        case .moodChange: return 4
        case .none: return 5
        }
    }

    @ViewBuilder
    private func ruleRow(_ label: String, _ keys: [MusicalKey]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).frame(width: 210, alignment: .leading)
            ForEach(keys, id: \.self) { k in
                Button { state.wheelKey = k } label: {
                    HStack(spacing: 3) { KeyBadge(key: k, size: 10.5); Text(k.traditional).font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                }.buttonStyle(.plain)
            }
        }
    }
}
