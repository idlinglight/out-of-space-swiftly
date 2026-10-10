import AppKit
import os
import SwiftUI

@main
struct OutOfSpaceSwiftlyApp: App {
    init() {
        let build = BuildInfo.current
        Log.app.notice("Launch: version \(build.version, privacy: .public) (\(build.build, privacy: .public)). \(build.summary, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
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
