import Foundation
import Synchronization

/// A new, empty directory under the test process's temporary directory. The caller removes it.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "oos-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

/// Waits until `condition` holds, looking every 20 ms and at most `looks` times; returns whether it does.
///
/// It counts looks, not time. On the main actor a deadline would be used up while other tests keep the main
/// actor busy (drawing tests do, for seconds), and what the condition waits for is often queued there too:
/// between two looks everything already queued gets its turn.
func waitUntil(looks: Int = 500, _ condition: () -> Bool) async throws -> Bool {
    for _ in 0 ..< looks {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A flag that can be set on one thread and read on another.
final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
