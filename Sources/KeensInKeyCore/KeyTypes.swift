import Foundation

/// Major / minor mode of a musical key.
public enum Mode: String, Codable, CaseIterable, Sendable {
    case major
    case minor
}

/// Notation used when displaying or writing a key.
public enum KeyNotation: String, Codable, CaseIterable, Sendable, Identifiable {
    case camelot
    case openKey
    case traditional
    case traditionalSharps

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .camelot: return "Camelot (8A, 8B)"
        case .openKey: return "Open Key (1m, 1d)"
        case .traditional: return "Traditional (Am, C)"
        case .traditionalSharps: return "Traditional, sharps (G#m, C#)"
        }
    }
}

/// Relationship between two keys on the Camelot wheel.
public enum HarmonicRelation: String, Codable, Sendable {
    case same
    case adjacent        // ±1 on the wheel, same letter
    case relative        // same number, other letter (relative major/minor)
    case energyBoost     // +2 on the wheel, same letter
    case moodChange      // +/-3 across letters (e.g. 8A -> 5B)
    case none

    public var label: String {
        switch self {
        case .same: return "Perfect match"
        case .adjacent: return "Compatible"
        case .relative: return "Relative key"
        case .energyBoost: return "Energy boost"
        case .moodChange: return "Mood change"
        case .none: return "Clash"
        }
    }

    public var isCompatible: Bool {
        switch self {
        case .same, .adjacent, .relative: return true
        default: return false
        }
    }
}

/// A musical key expressed as a pitch class (0 = C … 11 = B) plus mode,
/// with conversions to Camelot, Open Key and traditional notation.
public struct MusicalKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public let root: Int
    public let mode: Mode

    public init(root: Int, mode: Mode) {
        self.root = ((root % 12) + 12) % 12
        self.mode = mode
    }

    // Camelot-conventional spellings (as shown by Mixed In Key).
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let longNames = ["C", "D-flat", "D", "E-flat", "E", "F", "F-sharp", "G", "A-flat", "A", "B-flat", "B"]

    /// Root of the major key sharing this key's Camelot number.
    var relativeMajorRoot: Int { mode == .major ? root : (root + 3) % 12 }

    /// 1…12
    public var camelotNumber: Int {
        return (8 + 7 * relativeMajorRoot - 1) % 12 + 1
    }

    public var camelotLetter: String { mode == .major ? "B" : "A" }

    /// e.g. "8A"
    public var camelot: String { "\(camelotNumber)\(camelotLetter)" }

    /// Open Key notation (Traktor), e.g. "1m" for A minor.
    public var openKey: String {
        let n = (camelotNumber + 5 - 1) % 12 + 1
        return "\(n)\(mode == .major ? "d" : "m")"
    }

    /// e.g. "Am", "F#", "Dbm"
    public var traditional: String {
        MusicalKey.flatNames[root] + (mode == .minor ? "m" : "")
    }

    /// e.g. "G#m", "C#"
    public var traditionalSharps: String {
        MusicalKey.sharpNames[root] + (mode == .minor ? "m" : "")
    }

    /// e.g. "A minor", "F-sharp major"
    public var longName: String {
        MusicalKey.longNames[root] + (mode == .minor ? " minor" : " major")
    }

    public var description: String { "\(camelot) (\(traditional))" }

    public func formatted(_ notation: KeyNotation) -> String {
        switch notation {
        case .camelot: return camelot
        case .openKey: return openKey
        case .traditional: return traditional
        case .traditionalSharps: return traditionalSharps
        }
    }

    public var relativeKey: MusicalKey {
        mode == .major ? MusicalKey(root: root + 9, mode: .minor) : MusicalKey(root: root + 3, mode: .major)
    }

    // MARK: - Construction

    public static func fromCamelot(number: Int, mode: Mode) -> MusicalKey {
        let n = ((number - 1) % 12 + 12) % 12 + 1
        let majorRoot = ((7 * (n - 8)) % 12 + 12) % 12
        return mode == .major ? MusicalKey(root: majorRoot, mode: .major) : MusicalKey(root: majorRoot + 9, mode: .minor)
    }

    /// All 24 keys ordered by Camelot number, minor (A) first then major (B).
    public static var allKeys: [MusicalKey] {
        (1...12).flatMap { n in [fromCamelot(number: n, mode: .minor), fromCamelot(number: n, mode: .major)] }
    }

    /// Parses "8A", "8a", "1m", "1d", "Am", "A minor", "Abm", "G#min", "C", "C major", "Cmaj", "F#m", "A♭ minor" …
    public static func parse(_ raw: String) -> MusicalKey? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        s = s.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")

        // Camelot / Open Key: digits followed by A/B/m/d
        let scalars = Array(s)
        var digits = ""
        var idx = 0
        while idx < scalars.count, scalars[idx].isNumber { digits.append(scalars[idx]); idx += 1 }
        if !digits.isEmpty, idx < scalars.count, let n = Int(digits), (1...12).contains(n) {
            let rest = String(scalars[idx...]).trimmingCharacters(in: .whitespaces).lowercased()
            switch rest {
            case "a": return fromCamelot(number: n, mode: .minor)
            case "b": return fromCamelot(number: n, mode: .major)
            case "m": // open key minor
                let cam = (n - 5 - 1 + 24) % 12 + 1
                return fromCamelot(number: cam, mode: .minor)
            case "d":
                let cam = (n - 5 - 1 + 24) % 12 + 1
                return fromCamelot(number: cam, mode: .major)
            default: break
            }
        }

        // Traditional
        guard let first = scalars.first, let letterIndex = "CDEFGAB".firstIndex(of: Character(first.uppercased())) else { return nil }
        let baseRoots = [0, 2, 4, 5, 7, 9, 11]
        var root = baseRoots["CDEFGAB".distance(from: "CDEFGAB".startIndex, to: letterIndex)]
        var i = 1
        if i < scalars.count {
            if scalars[i] == "#" { root += 1; i += 1 }
            else if scalars[i] == "b" { root -= 1; i += 1 }
        }
        let rest = String(scalars[i...]).trimmingCharacters(in: .whitespaces).lowercased()
        let mode: Mode
        if rest.isEmpty || rest.hasPrefix("maj") || rest == "major" || rest == "dur" { mode = .major }
        else if rest == "m" || rest.hasPrefix("min") || rest == "minor" || rest == "moll" || rest == "-" { mode = .minor }
        else { return nil }
        return MusicalKey(root: root, mode: mode)
    }

    // MARK: - Harmonic mixing

    /// Camelot-wheel relationship of `other` relative to this key.
    public func relation(to other: MusicalKey) -> HarmonicRelation {
        let dn = ((other.camelotNumber - camelotNumber) % 12 + 12) % 12   // 0…11 clockwise distance
        let sameLetter = other.mode == mode
        if sameLetter {
            switch dn {
            case 0: return .same
            case 1, 11: return .adjacent
            case 2: return .energyBoost
            default: return .none
            }
        } else {
            switch dn {
            case 0: return .relative
            case 3, 9: return .moodChange
            default: return .none
            }
        }
    }

    /// Keys a DJ can mix into from this key without clashing (same, ±1, relative).
    public var compatibleKeys: [MusicalKey] {
        let n = camelotNumber
        return [
            self,
            MusicalKey.fromCamelot(number: n == 12 ? 1 : n + 1, mode: mode),
            MusicalKey.fromCamelot(number: n == 1 ? 12 : n - 1, mode: mode),
            relativeKey,
        ]
    }

    /// Energy-boost key (+2 on the wheel).
    public var energyBoostKey: MusicalKey {
        MusicalKey.fromCamelot(number: (camelotNumber + 2 - 1) % 12 + 1, mode: mode)
    }
}

// MARK: - Camelot wheel colours

public struct RGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public static func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh)
        let f = hh - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

public enum CamelotPalette {
    /// Hue for a Camelot number so that the wheel runs through the rainbow like Mixed In Key.
    public static func hue(for number: Int) -> Double {
        let h = 180.0 - 30.0 * Double(number)
        return (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Bright pastel badge colour.
    public static func color(for key: MusicalKey) -> RGB {
        let h = hue(for: key.camelotNumber)
        return key.mode == .minor ? RGB.hsb(h, 0.55, 0.92) : RGB.hsb(h, 0.42, 0.98)
    }

    public static func color(number: Int, mode: Mode) -> RGB {
        color(for: MusicalKey.fromCamelot(number: number, mode: mode))
    }
}
