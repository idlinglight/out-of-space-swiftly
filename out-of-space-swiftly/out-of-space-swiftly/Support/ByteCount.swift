import Foundation

/// Byte counts as the Finder writes them (decimal units: 1 GB = 1,000,000,000 bytes).
nonisolated enum ByteCount {
    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// Share of a whole, such as "12 %", or "< 1 %" for small non-zero parts.
    static func share(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0, part > 0 else { return "–" }
        let fraction = Double(part) / Double(whole)
        return fraction < 0.01 ? "< 1 %" : fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
