import SwiftUI

/// The mounted disks with how full they are; clicking one scans it.
struct VolumesOverview: View {
    let choose: (URL) -> Void
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(volumes) { volume in
                VolumeRow(volume: volume) { choose(volume.url) }
            }
        }
        .frame(maxWidth: 520)
        .task {
            // Loads off the main actor; a volume that does not answer in time is left out.
            volumes = await Volumes.browsable()
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let scan: () -> Void

    var body: some View {
        Button(action: scan) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(volume.name).fontWeight(.medium)
                        Spacer()
                        Text("\(ByteCount.text(volume.availableCapacity)) free of \(ByteCount.text(volume.totalCapacity))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    CapacityBar(total: volume.totalCapacity, used: volume.displayedUsedCapacity,
                                purgeable: volume.purgeableEstimate)
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help("Scan \(volume.name)")
    }

    private var symbol: String {
        if volume.isRootFileSystem { return "internaldrive" }
        if !volume.isLocal { return "server.rack" }
        return volume.isRemovable || volume.isEjectable ? "externaldrive" : "internaldrive"
    }
}

/// Used, purgeable and free space as one bar.
private struct CapacityBar: View {
    let total: Int64
    let used: Int64
    let purgeable: Int64

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = total > 0 ? width / CGFloat(total) : 0
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: CGFloat(max(0, used - purgeable)) * scale)
                Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: CGFloat(min(purgeable, used)) * scale)
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .help("\(ByteCount.text(used)) used, of which about \(ByteCount.text(purgeable)) can be freed by macOS when needed")
    }
}
