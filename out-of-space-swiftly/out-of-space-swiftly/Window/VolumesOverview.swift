import SwiftUI

/// The mounted disks with how full they are; clicking one scans it. A disk that has not answered after a
/// few seconds is shown as such and gets its figures when it answers.
struct VolumesOverview: View {
    let choose: (URL) -> Void
    /// Nil until there is something to show: every disk has answered, or the wait is over.
    @State private var list: VolumeList?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let list {
                if !list.isListed {
                    WaitingNote(text: "macOS has not said yet which disks there are.")
                }
                ForEach(list.entries) { entry in
                    if let volume = entry.info {
                        VolumeRow(volume: volume) { choose(volume.url) }
                    } else {
                        UnresponsiveVolumeRow(entry: entry) { choose(entry.url) }
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .task {
            // Read on threads of their own; the lists arrive here on the main actor.
            for await list in volumeLists() { self.list = list }
        }
    }

    private func volumeLists() -> AsyncStream<VolumeList> {
        #if DEBUG
        if let demo = DebugAids.demoVolumeLists() { return demo }
        #endif
        return Volumes.overview()
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

/// A disk that has not answered yet: its name and that it is being waited for, in the shape of the row it
/// becomes when it answers, so that nothing moves then. It can be scanned all the same; the scan then waits
/// for it, and can be stopped.
private struct UnresponsiveVolumeRow: View {
    let entry: VolumeList.Entry
    let scan: () -> Void

    var body: some View {
        Button(action: scan) {
            HStack(spacing: 12) {
                Image(systemName: entry.isRoot ? "internaldrive" : "externaldrive.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.name).fontWeight(.medium)
                        Spacer()
                        Text("Not responding")
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.small)
                    }
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help("""
            \(entry.name) has not answered yet. It may be asleep, disconnected or very busy; its sizes appear \
            here when it answers. Click to scan it anyway: the scan waits for it and can be stopped.
            """)
    }
}

/// A line that says what is being waited for.
private struct WaitingNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(10)
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
