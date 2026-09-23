import SwiftUI
import KeensInKeyCore

/// Coloured Camelot / key badge.
struct KeyBadge: View {
    let key: MusicalKey?
    var notation: KeyNotation = .camelot
    var size: CGFloat = 13

    var body: some View {
        if let key {
            Text(key.formatted(notation))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, size * 0.55)
                .padding(.vertical, size * 0.22)
                .background(key.badgeColor, in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
        } else {
            Text("—")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, size * 0.55)
                .padding(.vertical, size * 0.22)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
        }
    }
}

/// Ten-segment energy meter.
struct EnergyBar: View {
    let level: Int?
    var width: CGFloat = 60
    var height: CGFloat = 8

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1...10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level.map { i <= $0 ? energyColor($0) : Color.white.opacity(0.10) } ?? Color.white.opacity(0.06))
                    .frame(width: (width - 13.5) / 10, height: height)
            }
        }
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.9) : (destructive ? Theme.danger : Theme.text))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.accent : Theme.panelRaised)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textSecondary)
    }
}

struct StatPill: View {
    let label: String
    let value: String
    var color: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Status indicator used in the table.
struct StatusCell: View {
    let track: Track
    var body: some View {
        switch track.status {
        case .pending:
            Circle().fill(Color.white.opacity(0.18)).frame(width: 7, height: 7)
        case .queued:
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        case .analyzing:
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.05, track.progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .help(track.stage)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.success.opacity(0.8))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger).help(track.errorMessage ?? "Failed")
        }
    }
}
