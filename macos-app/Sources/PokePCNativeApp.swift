import SwiftUI
import AppKit

@main
struct PokePCNativeApp: App {
  @StateObject private var appState = AppState()
  private let runtimeManager = RuntimeManager()

  var body: some Scene {
    WindowGroup(id: "main") {
      RootView()
        .environmentObject(appState)
        .environment(\.runtimeManager, runtimeManager)
        .onAppear {
          runtimeManager.bind(appState: appState)
          Task { await runtimeManager.bootstrap() }
        }
    }
    .windowStyle(.titleBar)

    MenuBarExtra("Poke PC", systemImage: appState.menuBarSymbol) {
      MenuBarContentView()
        .environmentObject(appState)
        .environment(\.runtimeManager, runtimeManager)
    }
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Start Runtime") {
          Task { await runtimeManager.startRuntime() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Stop Runtime") {
          Task { await runtimeManager.stopRuntime() }
        }
        .keyboardShortcut(".", modifiers: [.command, .shift])
      }
    }
  }
}

private struct MenuBarContentView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.runtimeManager) private var runtimeManager
  @Environment(\.openWindow) private var openWindow
  @State private var showContainerInstallConfirmation = false

  private var showStartButton: Bool {
    switch appState.runtimeStatus {
    case .idle, .failed:
      return true
    default:
      return false
    }
  }

  private var showStopButton: Bool {
    switch appState.runtimeStatus {
    case .healthy, .preparing, .pullingImage, .creatingContainer, .booting, .degraded:
      return true
    case .idle, .stopping, .failed:
      return false
    }
  }

  private var showRefreshCredentialsButton: Bool {
    !appState.credentialsPresent || appState.authRequired
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Poke PC")
        .font(.headline)
      Text(appState.runtimeStatus.title)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Divider()

      Button("Open Dashboard") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }

      if !appState.containerCLIInstalled {
        Button("Setup First") {
          showContainerInstallConfirmation = true
        }

        Button("Refresh Setup Status") {
          Task { await runtimeManager.refreshContainerCLIStatus() }
        }
        .disabled(appState.isBusy)
      } else {
        if showStartButton {
          Button("Start Runtime") {
            Task { await runtimeManager.startRuntime() }
          }
          .disabled(appState.isBusy)
        }

        if showStopButton {
          Button("Stop Runtime") {
            Task { await runtimeManager.stopRuntime() }
          }
          .disabled(appState.isBusy)
        }

        if showRefreshCredentialsButton {
          Button("Refresh Credentials") {
            Task { await runtimeManager.refreshCredentialsStatus() }
          }
        }

        if appState.authRequired {
          Button("Sign In with Browser") {
            Task { await runtimeManager.startNativeLogin() }
          }

          Button("Copy Login Link") {
            Task { await runtimeManager.copyLoginLink() }
          }
          .disabled(appState.loginUrl.isEmpty)
        }
      }

      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(8)
    .task {
      await runtimeManager.refreshContainerCLIStatus()
    }
    .confirmationDialog(
      "Apple container CLI is required",
      isPresented: $showContainerInstallConfirmation,
      titleVisibility: .visible
    ) {
      Button("Install and Open Package") {
        Task { await runtimeManager.installContainerCLI() }
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This will download the latest .pkg from GitHub Releases and open the installer. Continue?")
    }
  }
}
