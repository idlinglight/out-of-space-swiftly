import Darwin

/// Why a directory could not be read (completely), from the errno the system gave.
nonisolated enum ScanFailure: Equatable, Sendable {
    /// POSIX permissions (`EACCES`).
    case noPermission
    /// macOS privacy protection or another policy (`EPERM`).
    case protectedByMacOS
    /// The content is in the cloud and downloading was not allowed (`EDEADLK`).
    case cloudOnly
    /// The storage did not answer (`ETIMEDOUT`, `EIO`, `ENXIO`, `ESTALE`).
    case unavailable
    case other(Int32)

    init(errno code: Int32) {
        switch code {
        case EACCES: self = .noPermission
        case EPERM: self = .protectedByMacOS
        case EDEADLK: self = .cloudOnly
        case ETIMEDOUT, EIO, ENXIO, ESTALE: self = .unavailable
        default: self = .other(code)
        }
    }

    var summary: String {
        switch self {
        case .noPermission: "No permission to read"
        case .protectedByMacOS: "Protected by macOS"
        case .cloudOnly: "Only in the cloud"
        case .unavailable: "Not available"
        case .other(let code): String(cString: strerror(code))
        }
    }
}
