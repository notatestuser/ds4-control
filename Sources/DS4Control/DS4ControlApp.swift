import SwiftUI

@main
struct DS4ControlApp: App {
    var body: some Scene {
        MenuBarExtra("DS4 Control", systemImage: "cpu") {
            Text("DS4 Control — scaffold")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
