import Foundation
import Testing
@testable import out_of_space_swiftly

/// What a window is told to scan, and the name it shows for it.
@MainActor
struct ScanTargetTests {
    @Test func aChosenURLIsTidiedUpWithoutALookAtTheDisk() {
        #expect(ScanTarget(URL(fileURLWithPath: "/no/such/place/../folder/", isDirectory: true)).path == "/no/such/folder")
        #expect(ScanTarget(URL(fileURLWithPath: "/", isDirectory: true)).path == "/")
    }

    @Test func thePlainNameIsTheEndOfThePath() {
        #expect(ScanTarget(path: "/no/such/folder").plainName == "folder")
        #expect(ScanTarget(path: "/").plainName == "/")
    }

    @Test func aWindowShowsThePlainNameUntilTheDiskHasGivenTheDisplayName() async throws {
        let fixture = try FixtureTree()
        try fixture.file("one.bin", size: 10_000)
        let target = ScanTarget(fixture.root)
        let model = ScanWindowModel()
        model.scanOptions = .fixture
        defer { model.close() }
        #expect(model.name(of: target) == fixture.root.lastPathComponent)
        model.start(target)
        // Starting a scan asks nothing of the disk on the main actor, so the name cannot be there yet.
        #expect(model.targetName == nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.targetName == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.targetName == FileManager.default.displayName(atPath: fixture.root.path))
        #expect(model.name(of: target) == model.targetName)
    }
}
