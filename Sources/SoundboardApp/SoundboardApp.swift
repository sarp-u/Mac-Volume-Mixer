import AudioRouterCore
import SwiftUI

@main
struct SoundboardApp: App {
    @StateObject private var router = RouterManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(router)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
