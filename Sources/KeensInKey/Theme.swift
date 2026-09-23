import SwiftUI
import KeensInKeyCore

/// Dark "DJ software" palette.
enum Theme {
    static let background = Color(red: 0.082, green: 0.090, blue: 0.118)      // #151720
    static let panel = Color(red: 0.110, green: 0.122, blue: 0.160)           // #1C1F29
    static let panelRaised = Color(red: 0.145, green: 0.160, blue: 0.205)     // #252934
    static let sidebar = Color(red: 0.067, green: 0.075, blue: 0.098)         // #111319
    static let border = Color.white.opacity(0.08)
    static let text = Color(red: 0.90, green: 0.91, blue: 0.94)
    static let textSecondary = Color(red: 0.55, green: 0.58, blue: 0.66)
    static let accent = Color(red: 1.0, green: 0.69, blue: 0.13)              // amber
    static let accentSoft = Color(red: 1.0, green: 0.69, blue: 0.13).opacity(0.18)
    static let teal = Color(red: 0.18, green: 0.83, blue: 0.75)
    static let danger = Color(red: 0.95, green: 0.33, blue: 0.30)
    static let success = Color(red: 0.45, green: 0.85, blue: 0.45)
    static let waveform = Color(red: 0.32, green: 0.66, blue: 0.95)
    static let waveformDim = Color(red: 0.32, green: 0.66, blue: 0.95).opacity(0.35)
}

extension Color {
    init(rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }

    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func camelot(_ key: MusicalKey) -> Color { Color(rgb: CamelotPalette.color(for: key)) }
}

extension MusicalKey {
    var badgeColor: Color { Color.camelot(self) }
}

/// Energy 1…10 → colour from cool to hot.
func energyColor(_ level: Int) -> Color {
    let t = Double(max(1, min(10, level)) - 1) / 9
    return Color(hue: 0.55 - 0.55 * t, saturation: 0.75, brightness: 0.95)
}
