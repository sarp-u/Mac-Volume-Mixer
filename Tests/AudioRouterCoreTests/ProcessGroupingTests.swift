import CoreAudio
import XCTest

@testable import AudioRouterCore

final class ProcessGroupingTests: XCTestCase {

    private func process(
        _ id: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        name: String,
        playing: Bool = false
    ) -> AudioProcess {
        AudioProcess(
            id: id, pid: pid, bundleID: bundleID, name: name,
            isPlaying: playing, isRecording: false
        )
    }

    private func owner(_ bundleID: String, _ name: String, pid: pid_t, isUserApp: Bool = true)
        -> AudioProcesses.OwningApplication
    {
        AudioProcesses.OwningApplication(
            pid: pid, bundleID: bundleID, name: name, isUserApplication: isUserApp
        )
    }

    func testHelpersAreGroupedIntoOwningApplication() {
        let processes = [
            process(1, pid: 100, bundleID: "jp.naver.line.mac", name: "LINE"),
            process(2, pid: 101, bundleID: "LINE.AudioService", name: "LINE.AudioService", playing: true),
            process(3, pid: 102, bundleID: "LINE.MediaService", name: "LINE.MediaService"),
        ]
        let line = owner("jp.naver.line.mac", "LINE", pid: 100)

        let groups = AudioProcesses.makeGroups(from: processes) { _ in line }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "jp.naver.line.mac")
        XCTAssertEqual(groups[0].name, "LINE")
        XCTAssertEqual(groups[0].processes.count, 3)
        XCTAssertEqual(groups[0].processObjectIDs, [1, 2, 3])
    }

    func testGroupIsPlayingWhenAnyMemberIsPlaying() {
        let processes = [
            process(1, pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome"),
            process(2, pid: 101, bundleID: "com.google.Chrome.helper", name: "Helper", playing: true),
        ]
        let chrome = owner("com.google.Chrome", "Google Chrome", pid: 100)

        let groups = AudioProcesses.makeGroups(from: processes) { _ in chrome }

        XCTAssertTrue(groups[0].isPlaying)
    }

    func testProcessWithoutOwnerIsClassifiedAsSystem() {
        let processes = [process(1, pid: 200, bundleID: "com.apple.audiomxd", name: "audiomxd")]

        let groups = AudioProcesses.makeGroups(from: processes) { _ in nil }

        XCTAssertTrue(groups[0].isSystemProcess)
        XCTAssertEqual(groups[0].key, "com.apple.audiomxd")
    }

    func testNonRegularApplicationIsClassifiedAsSystem() {
        let processes = [process(1, pid: 300, bundleID: "com.apple.controlcenter", name: "Control Center")]
        let controlCenter = owner(
            "com.apple.controlcenter", "Control Center", pid: 300, isUserApp: false
        )

        let groups = AudioProcesses.makeGroups(from: processes) { _ in controlCenter }

        XCTAssertTrue(groups[0].isSystemProcess)
    }

    func testSortingPutsPlayingFirstAndSystemLast() {
        let processes = [
            process(1, pid: 100, bundleID: "com.apple.audiomxd", name: "audiomxd"),
            process(2, pid: 101, bundleID: "com.b.app", name: "B App"),
            process(3, pid: 102, bundleID: "com.a.app", name: "A App"),
            process(4, pid: 103, bundleID: "com.z.app", name: "Z App", playing: true),
        ]
        let owners: [pid_t: AudioProcesses.OwningApplication?] = [
            100: nil,
            101: owner("com.b.app", "B App", pid: 101),
            102: owner("com.a.app", "A App", pid: 102),
            103: owner("com.z.app", "Z App", pid: 103),
        ]

        let groups = AudioProcesses.makeGroups(from: processes) { owners[$0] ?? nil }

        XCTAssertEqual(groups.map(\.name), ["Z App", "A App", "B App", "audiomxd"])
    }

    func testProcessesWithoutBundleIDGetDistinctKeys() {
        let processes = [
            process(1, pid: 400, bundleID: nil, name: "foo"),
            process(2, pid: 401, bundleID: nil, name: "bar"),
        ]

        let groups = AudioProcesses.makeGroups(from: processes) { _ in nil }

        XCTAssertEqual(Set(groups.map(\.key)), ["pid:400", "pid:401"])
    }
}
