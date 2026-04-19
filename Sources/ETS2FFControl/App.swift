import SwiftUI
import AppKit

@main
struct ETS2FFControlApp: App {
    @StateObject private var client = ControlClient()

    var body: some Scene {
        WindowGroup("Thrustmaster Wheel Control") {
            ContentView()
                .environmentObject(client)
                .onAppear { client.start() }
                .onDisappear { client.stop() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
