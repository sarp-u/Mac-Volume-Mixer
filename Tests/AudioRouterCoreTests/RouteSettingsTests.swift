import CoreAudio
import XCTest

@testable import AudioRouterCore

final class RouteSettingsTests: XCTestCase {

    func testIsPassthroughOnlyWhenEverythingIsDefault() {
        XCTAssertTrue(RouteSettings().isPassthrough)

        XCTAssertFalse(RouteSettings(outputDeviceUID: "SomeDevice").isPassthrough)
        XCTAssertFalse(RouteSettings(volume: 0.5).isPassthrough)
        XCTAssertFalse(RouteSettings(muted: true).isPassthrough)
        XCTAssertFalse(RouteSettings(balance: -0.3).isPassthrough)
    }

    func testCodableRoundTrip() throws {
        let original = RouteSettings(
            outputDeviceUID: "BuiltInSpeakerDevice",
            volume: 0.35,
            muted: true,
            balance: 0.5,
            displayName: "Spotify"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteSettings.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

final class CoreAudioErrorTests: XCTestCase {

    func testFourCharCodeIsRestoredInDescription() {
        let status = OSStatus(bitPattern: 0x6E6F7065)
        let error = CoreAudioError(status: status, operation: "Test")

        XCTAssertTrue(error.description.contains("'nope'"), error.description)
        XCTAssertTrue(error.description.contains("Test"))
    }

    func testNonPrintableStatusFallsBackToNumber() {
        let error = CoreAudioError(status: -50, operation: "Test")

        XCTAssertTrue(error.description.contains("-50"), error.description)
        XCTAssertFalse(error.description.contains("'"), error.description)
    }
}
