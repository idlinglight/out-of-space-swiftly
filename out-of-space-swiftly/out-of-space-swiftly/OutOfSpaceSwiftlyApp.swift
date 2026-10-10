import AppKit
import os
import SwiftUI

@main
struct OutOfSpaceSwiftlyApp: App {
    init() {
        let build = BuildInfo.current
        Log.app.notice("Launch: version \(build.version, privacy: .public) (\(build.build, privacy: .public)). \(build.summary, privacy: .public)")
        ScanProcessSettings.applyAtLaunch()
    }

    var body: some Scene {
        WindowGroup("Out Of Space Swiftly", for: ScanTarget.self) { $target in
            ScanWindow(target: $target)
        }
        .commands {
            ScanCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Out Of Space Swiftly") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: BuildInfo.current.summary),
                    ])
                }
            }
        }
    }
}
