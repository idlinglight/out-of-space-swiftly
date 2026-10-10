import SwiftUI

/// What the scanner is doing: counts, the folder it is reading, and folders that keep it waiting.
struct ScanProgressView: View {
    let model: ScanWindowModel

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning \(model.target?.displayName ?? "")…")
                .font(.title3)
            ScanCounts(progress: model.progress)
            Text(model.progress.currentPath ?? " ")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            if !model.progress.slowPaths.isEmpty {
                SlowFolders(paths: model.progress.slowPaths)
            }
            Button("Stop") { model.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, minHeight: 380)
    }
}

private struct ScanCounts: View {
    let progress: ScanProgress

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Found").foregroundStyle(.secondary)
                Text(ByteCount.text(progress.bytes)).monospacedDigit()
            }
            GridRow {
                Text("Files").foregroundStyle(.secondary)
                Text(progress.files.formatted()).monospacedDigit()
            }
            GridRow {
                Text("Folders").foregroundStyle(.secondary)
                Text(progress.directories.formatted()).monospacedDigit()
            }
            if progress.failures > 0 {
                GridRow {
                    Text("Not readable").foregroundStyle(.secondary)
                    Text(progress.failures.formatted()).monospacedDigit()
                }
            }
        }
    }
}

private struct SlowFolders: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Waiting for", systemImage: "hourglass")
                .foregroundStyle(.orange)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
