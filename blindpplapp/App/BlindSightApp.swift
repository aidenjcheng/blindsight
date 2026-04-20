import SwiftUI
import os

@main
struct BlindSightApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    BNLog.app.info("BlindSight launched")
                    configureAccessibility()
                }
        }
    }

    private func configureAccessibility() {
        UIApplication.shared.isIdleTimerDisabled = true
        BNLog.app.info("Idle timer disabled for active camera use")
    }
}

// MARK: - Root content view with animated phase transitions

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            HomeView()
        }
    }
}
