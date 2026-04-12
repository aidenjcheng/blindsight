import SwiftUI
import os

@main
struct BlindNavApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    BNLog.app.info("BlindNav launched")
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
            ZStack {
                switch appState.session.phase {
                case .idle, .listening:
                    HomeView()
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                case .planning, .navigating, .arrived:
                    NavigationActiveView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: isNavigating)
        }
    }

    private var isNavigating: Bool {
        switch appState.session.phase {
        case .idle, .listening: return false
        case .planning, .navigating, .arrived: return true
        }
    }
}
