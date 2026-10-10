import Darwin
import os

/// Process-wide settings that keep scanning from changing what it looks at (ADR-0004).
nonisolated enum ScanProcessSettings {
    /// Call once at launch: no automounts triggered by lookups, no access-time updates, and enough file
    /// descriptors for several scans. Logs what is in effect.
    static func applyAtLaunch() {
        let triggers = setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS, IOPOL_VFS_TRIGGER_RESOLVE_OFF)
        let accessTimes = setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF)
        let descriptors = raiseDescriptorLimit(to: 10_240)
        Log.scan.notice("""
            Process settings: trigger resolve off \(triggers == 0, privacy: .public), \
            atime updates off \(accessTimes == 0, privacy: .public), \
            descriptor limit \(descriptors, privacy: .public), \
            dataless materialization (process) \(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS), privacy: .public)
            """)
    }

    /// Call at the start of every scanning thread: cloud files are not downloaded (calls that would need
    /// them fail with `EDEADLK`), and the thread's disk access yields to interactive work.
    static func applyToScanThread() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
    }

    /// Raises the soft limit for open files (launchd starts apps with 256). Returns the limit in effect.
    @discardableResult
    static func raiseDescriptorLimit(to wanted: rlim_t) -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let target = min(wanted, limit.rlim_max)
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &limit) != 0 { _ = getrlimit(RLIMIT_NOFILE, &limit) }
        }
        return limit.rlim_cur
    }
}
