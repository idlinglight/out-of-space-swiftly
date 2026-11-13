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
                    VolumeRow(entry: entry) { scan(entry.url) }
                }
            }
        }
        .frame(maxWidth: 520)
        .task {
            // Read on threads of their own; the lists arrive here on the main actor.
            for await list in volumeLists() { self.list = list }
        }
    }

    private func scan(_ url: URL) {
        #if DEBUG
        // The made-up disks are there to be looked at; nothing is mounted where they point.
        if DebugAids.showsDemoVolumes { return }
        #endif
        choose(url)
    }

    private func volumeLists() -> AsyncStream<VolumeList> {
        #if DEBUG
        if let demo = DebugAids.demoVolumeLists() { return demo }
        #endif
        return Volumes.overview()
    }
}

/// One disk: with its sizes once it has answered, until then as not responding. Both in one shape, so that
/// nothing moves when it answers. A disk that has not answered can be scanned all the same; the scan then
/// waits for it, and can be stopped.
private struct VolumeRow: View {
    let entry: VolumeList.Entry
    let scan: () -> Void

    var body: some View {
        Button(action: scan) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(entry.info == nil ? .tertiary : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.name).fontWeight(.medium)
                        Spacer()
                        if let volume = entry.info {
                            Text("\(ByteCount.text(volume.availableCapacity)) free of \(ByteCount.text(volume.totalCapacity))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("Not responding")
                                .foregroundStyle(.secondary)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let volume = entry.info {
                        CapacityBar(total: volume.totalCapacity, used: volume.displayedUsedCapacity,
                                    purgeable: volume.purgeableEstimate)
                    } else {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: CapacityBar.height)
                    }
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }

    private var symbol: String {
        guard let volume = entry.info else { return entry.isRoot ? "internaldrive" : "externaldrive.badge.questionmark" }
        if volume.isRootFileSystem { return "internaldrive" }
        if !volume.isLocal { return "server.rack" }
        return volume.isRemovable || volume.isEjectable ? "externaldrive" : "internaldrive"
    }

    private var help: String {
        guard entry.info == nil else { return "Scan \(entry.name)" }
        return """
            \(entry.name) has not answered yet. It may be asleep, disconnected or very busy; its sizes appear \
            here when it answers. Click to scan it anyway: the scan waits for it and can be stopped.
            """
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
    static let height: CGFloat = 6
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
        .frame(height: Self.height)
        .help("\(ByteCount.text(used)) used, of which about \(ByteCount.text(purgeable)) can be freed by macOS when needed")
    }
}
