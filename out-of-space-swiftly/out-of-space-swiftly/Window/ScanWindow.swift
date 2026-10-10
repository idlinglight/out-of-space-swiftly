import SwiftUI

/// The content of one window: a place to choose a folder, the scan in progress, or its result.
struct ScanWindow: View {
    /// The window's scene value; setting it records which folder the window shows.
    @Binding var target: ScanTarget?
    @State private var model = ScanWindowModel()

    var body: some View {
        ScanWindowContent(model: model, choose: choose)
            .navigationTitle(target?.displayName ?? "Out Of Space Swiftly")
            .navigationSubtitle(model.phase == .finished ? ByteCount.text(model.totalSize) : "")
            .focusedSceneValue(\.scanWindow, model)
            .onDisappear { model.close() }
            #if DEBUG
            .onAppear { DebugAids.attach(to: model, choose: choose) }
            #endif
            .task(id: target) {
                guard let target, target != model.target else { return }
                model.start(target)
            }
            .alert("Something went wrong", isPresented: Binding { model.problem != nil } set: { _ in model.problem = nil }) {
                Button("OK") {}
            } message: {
                Text(model.problem ?? "")
            }
    }

    private func choose(_ url: URL) {
        target = ScanTarget(path: url.resolvingSymlinksInPath().path)
    }
}

/// Switches on the model's phase; kept separate so the window's own body reads little of the model.
private struct ScanWindowContent: View {
    let model: ScanWindowModel
    let choose: (URL) -> Void

    var body: some View {
        switch model.phase {
        case .choosing:
            StartView(choose: choose)
        case .scanning:
            ScanProgressView(model: model)
        case .finished:
            ScanView(model: model, choose: choose)
        }
    }
}
