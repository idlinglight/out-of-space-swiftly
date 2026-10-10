import Foundation

/// What the running build was made from. `Scripts/build.sh` stamps commit, branch, dirty flag and date into
/// Info.plist through build settings; builds made by Xcode directly carry no stamp.
nonisolated struct BuildInfo: Sendable, Equatable {
    /// CFBundleShortVersionString, the marketing version.
    var version: String
    /// CFBundleVersion; the build script sets it to the commit count.
    var build: String
    var commit: String?
    var branch: String?
    var buildDate: String?
    var hasUncommittedChanges: Bool

    static let current = BuildInfo(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        func text(_ key: String) -> String? {
            let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }
        version = text("CFBundleShortVersionString") ?? "?"
        build = text("CFBundleVersion") ?? "?"
        commit = text("OOSSCommit")
        branch = text("OOSSBranch")
        buildDate = text("OOSSBuildDate")
        hasUncommittedChanges = text("OOSSDirty") == "1"
    }

    /// One line for the About panel and the launch log entry.
    var summary: String {
        guard let commit else { return "Built in Xcode, commit unknown." }
        var line = "Commit \(commit)"
        if let branch { line += " on \(branch)" }
        if hasUncommittedChanges { line += ", with uncommitted changes" }
        if let buildDate { line += ", built \(buildDate)" }
        return line + "."
    }
}
