import SwiftUI
import UniformTypeIdentifiers

/// The empty window: choose a folder (button, drop, or a common place) to scan.
struct StartView: View {
    let choose: (URL) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "square.split.2x2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Where did the space go?")
                    .font(.title2)
                Text("Choose a folder or a disk, or drop a folder here.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Choose Folder…", action: openPanel)
                    .keyboardShortcut(.defaultAction)
                Button("Home Folder") { choose(URL(fileURLWithPath: NSHomeDirectory())) }
            }
            .controlSize(.large)
            VolumesOverview(choose: choose)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 3)
                .padding(8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || Self.isDirectory(url) else { return false }
            choose(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .frame(minWidth: 600, minHeight: 460)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan."
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

#Preview {
    StartView { _ in }
}
