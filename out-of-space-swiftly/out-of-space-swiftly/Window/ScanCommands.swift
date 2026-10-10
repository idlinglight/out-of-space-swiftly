import SwiftUI

extension FocusedValues {
    /// The model of the key window, for menu commands.
    @Entry var scanWindow: ScanWindowModel?
}

/// Menu commands that act on the key window's scan.
struct ScanCommands: Commands {
    @FocusedValue(\.scanWindow) private var model

    var body: some Commands {
        CommandMenu("Scan") {
            Button("Scan Again") { model?.rescan() }
                .keyboardShortcut("r")
                .disabled(model?.target == nil || model?.isScanning == true)
            Button("Stop") { model?.cancel() }
                .keyboardShortcut(".")
                .disabled(model?.isScanning != true)
            Divider()
            Button("Zoom In") {
                if let model, let id = model.selection { model.zoom(into: id) }
            }
            .keyboardShortcut(.downArrow)
            .disabled(!(model?.selection.map { model?.tree?.isContainer($0) == true } ?? false))
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut(.upArrow)
                .disabled(model?.canZoomOut != true)
            Divider()
            Button("Show in Finder") {
                if let model, let id = model.selection { model.revealInFinder(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.selection == nil)
            Button("Copy Path") {
                if let model, let id = model.selection { model.copyPath(id) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model?.selection == nil)
            Button("Move to Trash…") {
                if let model, let id = model.selection { model.pendingTrash = id }
            }
            .keyboardShortcut(.delete)
            .disabled(!(model?.selection.map { model?.canMoveToTrash($0) == true } ?? false))
        }
    }
}
