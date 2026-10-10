#if DEBUG
import AppKit
import os
import ScreenCaptureKit

/// Development aids, compiled into Debug builds only, so the app can be driven and inspected from a shell
/// session where nobody looks at the screen. All of them act on the first window and are switched on by
/// environment variables:
///
/// - `OOSS_SCAN=<path>`: scan that folder at launch. Use generated trees or system folders, never personal
///   or protected places (see CLAUDE.md).
/// - `OOSS_ZOOM=<relative path>`: once the scan is done, zoom into that folder (relative to the root).
/// - `OOSS_SELECT=<relative path>`: then select that item.
/// - `OOSS_HOVER=<relative path>`: then set that item as hovered, for the status bar (the treemap's hover
///   outline follows the real pointer).
/// - `OOSS_WINDOW_SIZE=<width>x<height>`: resize the window at launch.
/// - `OOSS_SNAPSHOT=/path/to/file.png`: once the scan is done (or after `OOSS_SNAPSHOT_DELAY` seconds,
///   default 60), write an image of the window there and a text dump next to it (`file.txt`) with the
///   model's state and the view hierarchy. `OOSS_SNAPSHOT_QUIT=1` quits afterwards. The image comes from
///   ScreenCaptureKit when the app may already record the screen (it never asks), otherwise from drawing
///   the window's views, which can miss materials such as the sidebar's. `OOSS_SNAPSHOT_WAIT=<seconds>` waits
///   that much longer after the scan, for example to let changes on disk be picked up first.
///
///     OOSS_SCAN=/usr OOSS_SNAPSHOT=/tmp/oos.png OOSS_SNAPSHOT_QUIT=1 \
///         path/to/out-of-space-swiftly.app/Contents/MacOS/out-of-space-swiftly
@MainActor
enum DebugAids {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var attached = false

    /// Called by every window when it appears; acts on the first one only.
    static func attach(to model: ScanWindowModel, choose: @escaping (URL) -> Void) {
        guard !attached else { return }
        attached = true
        if let size = environment["OOSS_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
        if let path = environment["OOSS_SCAN"] {
            choose(URL(fileURLWithPath: path))
        }
        guard environment["OOSS_SCAN"] != nil || environment["OOSS_SNAPSHOT"] != nil else { return }
        Task {
            await waitForScan(model)
            applySelection(to: model)
            if let path = environment["OOSS_SNAPSHOT"] {
                NSApp.activate()
                try? await Task.sleep(for: .seconds(1 + (Double(environment["OOSS_SNAPSHOT_WAIT"] ?? "") ?? 0)))
                await write(to: path, model: model)
                if environment["OOSS_SNAPSHOT_QUIT"] == "1" {
                    NSApp.terminate(nil)
                    try? await Task.sleep(for: .seconds(2))
                    exit(0)
                }
            }
        }
    }

    private static func waitForScan(_ model: ScanWindowModel) async {
        let limit = Double(environment["OOSS_SNAPSHOT_DELAY"] ?? "") ?? 60
        let deadline = Date.now.addingTimeInterval(limit)
        try? await Task.sleep(for: .milliseconds(300))
        while model.phase != .finished, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func applySelection(to model: ScanWindowModel) {
        guard let tree = model.tree else { return }
        if let path = environment["OOSS_ZOOM"], let id = find(path, in: tree) { model.zoom(into: id) }
        if let path = environment["OOSS_SELECT"], let id = find(path, in: tree) { model.selection = id }
        if let path = environment["OOSS_HOVER"], let id = find(path, in: tree) { model.hovered = id }
    }

    private static func find(_ path: String, in tree: ScanTree) -> NodeID? {
        guard let id = tree.node(atRelativePath: path) else {
            Log.app.error("Debug aids: no \(path, privacy: .public) in the scan")
            return nil
        }
        return id
    }

    static func write(to path: String, model: ScanWindowModel) async {
        var report = "== Model ==\n\(summary(of: model))\n\n== Windows ==\n"
        for window in NSApp.windows {
            report += "\(type(of: window)) \"\(window.title)\" visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(window.frame)\n"
        }
        let target = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
        var image: CGImage?
        if let window = target?.attachedSheet ?? target {
            if let frameView = window.contentView?.superview {
                report += "\n== View hierarchy of \"\(window.title)\" ==\n"
                dump(frameView, depth: 0, into: &report)
            }
            if CGPreflightScreenCaptureAccess() {
                do {
                    image = try await captureWithScreenCaptureKit(window)
                    report += "\nImage: ScreenCaptureKit\n"
                } catch {
                    report += "\nScreenCaptureKit failed: \(error.localizedDescription)\n"
                }
            }
            if image == nil {
                image = renderViews(of: window)
                report += "\nImage: view drawing\n"
            }
        } else {
            report += "\nNo visible window.\n"
        }
        if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        let textPath = (path as NSString).deletingPathExtension + ".txt"
        try? report.write(toFile: textPath, atomically: true, encoding: .utf8)
        Log.app.info("Snapshot written to \(path, privacy: .public)")
    }

    private static func summary(of model: ScanWindowModel) -> String {
        var lines = ["target: \(model.target?.path ?? "none")", "phase: \(model.phase)"]
        let progress = model.progress
        lines.append("progress: \(progress.files) files, \(progress.directories) folders, \(progress.bytes) bytes, \(progress.failures) failures")
        if let summary = model.lastScan { lines.append("last scan: \(summary)") }
        if let tree = model.tree {
            lines.append("nodes: \(tree.count), root size: \(tree.size(of: tree.root))")
            lines.append("zoom: \(tree.path(of: model.zoom))")
            lines.append("selection: \(model.selection.map { tree.path(of: $0) } ?? "none")")
            lines.append("hovered: \(model.hovered.map { tree.path(of: $0) } ?? "none")")
            lines.append("zoom children (largest 10):")
            for id in tree.children(of: model.zoom).prefix(10) {
                lines.append("  \(tree.name(of: id)) \(tree.size(of: id)) \(tree.kind(of: id)) \(tree.flags(of: id).rawValue)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line per view: class, frame, and what a table, text field or button holds.
    private static func dump(_ view: NSView, depth: Int, into report: inout String) {
        guard depth < 40 else { return }
        var parts = ["\(type(of: view))"]
        let frame = view.frame
        parts.append("[\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]")
        if view.isHidden { parts.append("hidden") }
        if let table = view as? NSTableView {
            parts.append("rows=\(table.numberOfRows) selected=\(Array(table.selectedRowIndexes))")
        }
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            parts.append("text=\"\(field.stringValue.prefix(80))\"")
        }
        if let button = view as? NSButton, !button.title.isEmpty {
            parts.append("title=\"\(button.title)\"")
        }
        report += String(repeating: "  ", count: depth) + parts.joined(separator: " ") + "\n"
        for subview in view.subviews {
            dump(subview, depth: depth + 1, into: &report)
        }
    }

    /// The window as the window server shows it. Needs screen-recording permission, which is not requested.
    private static func captureWithScreenCaptureKit(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "window not listed as shareable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(target.frame.width * scale)
        configuration.height = Int(target.frame.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Fallback: asks the window's views to draw themselves into a bitmap.
    private static func renderViews(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }
}
#endif
