import Testing
@testable import out_of_space_swiftly

struct BuildInfoTests {
    @Test func unstampedBuildSaysSo() {
        let info = BuildInfo(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "OOSSCommit": ""])
        #expect(info.commit == nil)
        #expect(info.summary == "Built in Xcode, commit unknown.")
    }

    @Test func stampedBuildNamesCommitBranchAndDate() {
        let info = BuildInfo(info: [
            "CFBundleShortVersionString": "0.1",
            "CFBundleVersion": "12",
            "OOSSCommit": "abc1234",
            "OOSSBranch": "main",
            "OOSSBuildDate": "2026-10-10 12:00",
            "OOSSDirty": "1",
        ])
        #expect(info.build == "12")
        #expect(info.summary == "Commit abc1234 on main, with uncommitted changes, built 2026-10-10 12:00.")
    }
}
