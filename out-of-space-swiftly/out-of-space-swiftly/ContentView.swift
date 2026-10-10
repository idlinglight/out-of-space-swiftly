import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView("Nothing scanned yet", systemImage: "square.grid.3x3.square")
            .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
