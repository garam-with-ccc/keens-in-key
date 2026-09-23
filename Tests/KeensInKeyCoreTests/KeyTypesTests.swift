import XCTest
@testable import KeensInKeyCore

final class KeyTypesTests: XCTestCase {
    func testCamelotMapping() {
        XCTAssertEqual(MusicalKey(root: 9, mode: .minor).camelot, "8A")   // A minor
        XCTAssertEqual(MusicalKey(root: 0, mode: .major).camelot, "8B")   // C major
        XCTAssertEqual(MusicalKey(root: 11, mode: .major).camelot, "1B")  // B major
        XCTAssertEqual(MusicalKey(root: 8, mode: .minor).camelot, "1A")   // Ab minor
        XCTAssertEqual(MusicalKey(root: 3, mode: .minor).camelot, "2A")   // Eb minor
        XCTAssertEqual(MusicalKey(root: 6, mode: .major).camelot, "2B")   // F# major
        XCTAssertEqual(MusicalKey(root: 4, mode: .major).camelot, "12B")  // E major
        XCTAssertEqual(MusicalKey(root: 1, mode: .minor).camelot, "12A")  // Db minor
    }

    func testRoundTrip() {
        for key in MusicalKey.allKeys {
            XCTAssertEqual(MusicalKey.parse(key.camelot), key)
            XCTAssertEqual(MusicalKey.parse(key.openKey), key)
            XCTAssertEqual(MusicalKey.parse(key.traditional), key)
            XCTAssertEqual(MusicalKey.parse(key.traditionalSharps), key)
            XCTAssertEqual(MusicalKey.parse(key.longName.replacingOccurrences(of: "-flat", with: "b").replacingOccurrences(of: "-sharp", with: "#")), key)
        }
        XCTAssertEqual(MusicalKey.allKeys.count, 24)
        XCTAssertEqual(Set(MusicalKey.allKeys.map(\.camelot)).count, 24)
    }

    func testOpenKey() {
        XCTAssertEqual(MusicalKey.parse("8A")!.openKey, "1m")
        XCTAssertEqual(MusicalKey.parse("8B")!.openKey, "1d")
        XCTAssertEqual(MusicalKey.parse("1B")!.openKey, "6d")
        XCTAssertEqual(MusicalKey.parse("12A")!.openKey, "5m")
    }

    func testRelations() {
        let am = MusicalKey.parse("8A")!
        XCTAssertEqual(am.relation(to: MusicalKey.parse("8A")!), .same)
        XCTAssertEqual(am.relation(to: MusicalKey.parse("9A")!), .adjacent)
        XCTAssertEqual(am.relation(to: MusicalKey.parse("7A")!), .adjacent)
        XCTAssertEqual(am.relation(to: MusicalKey.parse("8B")!), .relative)
        XCTAssertEqual(am.relation(to: MusicalKey.parse("10A")!), .energyBoost)
        XCTAssertEqual(am.relation(to: MusicalKey.parse("3B")!), .none)
        XCTAssertEqual(MusicalKey.parse("12A")!.relation(to: MusicalKey.parse("1A")!), .adjacent)
        XCTAssertEqual(am.compatibleKeys.map(\.camelot), ["8A", "9A", "7A", "8B"])
    }

    func testParsingVariants() {
        XCTAssertEqual(MusicalKey.parse("A minor")?.camelot, "8A")
        XCTAssertEqual(MusicalKey.parse("Amin")?.camelot, "8A")
        XCTAssertEqual(MusicalKey.parse("C major")?.camelot, "8B")
        XCTAssertEqual(MusicalKey.parse("Cmaj")?.camelot, "8B")
        XCTAssertEqual(MusicalKey.parse("G#m")?.camelot, "1A")
        XCTAssertEqual(MusicalKey.parse("Abm")?.camelot, "1A")
        XCTAssertEqual(MusicalKey.parse("A♭ minor")?.camelot, "1A")
        XCTAssertEqual(MusicalKey.parse("f#")?.camelot, "2B")
        XCTAssertNil(MusicalKey.parse("hello"))
        XCTAssertNil(MusicalKey.parse(""))
    }
}
