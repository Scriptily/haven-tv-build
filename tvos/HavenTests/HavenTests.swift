import XCTest
@testable import Haven

final class HavenTests: XCTestCase {

    /// subscribe_entities: the first event adds everything, later ones change, remove attributes, remove entities
    func testEntityDiff() {
        var s: [String: EntityState] = [:]
        EntityDiff.apply(["a": [
            "light.desk": ["s": "on", "a": ["friendly_name": "Desk", "brightness": 200], "lc": 100.0],
            "sensor.temp": ["s": "22.5", "a": ["unit_of_measurement": "°C"], "lc": 50.0, "lu": 60.0],
        ]], to: &s)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s["light.desk"]?.state, "on")
        XCTAssertEqual(s["light.desk"]?.lastUpdated, 100)
        XCTAssertEqual(s["sensor.temp"]?.lastUpdated, 60)
        XCTAssertEqual(s["sensor.temp"]?.number, 22.5)

        EntityDiff.apply(["c": ["light.desk": ["+": ["s": "off", "lc": 200.0, "a": ["color_mode": "onoff"]], "-": ["a": ["brightness"]]]]], to: &s)
        XCTAssertEqual(s["light.desk"]?.state, "off")
        XCTAssertNil(s["light.desk"]?.attributes["brightness"])
        XCTAssertEqual(s["light.desk"]?.attributes["color_mode"] as? String, "onoff")
        XCTAssertEqual(s["light.desk"]?.name, "Desk")
        XCTAssertEqual(s["light.desk"]?.lastChanged, 200)

        // only lu moves (an attribute update): last changed stays
        EntityDiff.apply(["c": ["light.desk": ["+": ["lu": 250.0]]]], to: &s)
        XCTAssertEqual(s["light.desk"]?.lastChanged, 200)
        XCTAssertEqual(s["light.desk"]?.lastUpdated, 250)

        // a change for an entity it doesn't know is ignored, removal removes
        EntityDiff.apply(["c": ["switch.ghost": ["+": ["s": "on"]]], "r": ["sensor.temp"]], to: &s)
        XCTAssertNil(s["switch.ghost"])
        XCTAssertNil(s["sensor.temp"])
        XCTAssertEqual(s.count, 1)
    }

    @MainActor
    func testPairingCodeIsSixDigits() {
        let p = Pairing(settings: Settings())
        XCTAssertEqual(p.code.count, 6)
        XCTAssertTrue(p.code.allSatisfy(\.isNumber))
    }

    @MainActor
    func testVersionString() {
        XCTAssertTrue(Remote.version.contains("("))
    }
}
