import SwiftUI

struct RootView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    Group {
      switch appState.launchStage {
      case .onboarding:
        OnboardingView()
      case .dashboard:
        DashboardView()
      }
    }
    .frame(minWidth: 980, minHeight: 640)
    .background(Brand.background.ignoresSafeArea())
  }
}

struct OnboardingView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.runtimeManager) private var runtimeManager
  @State private var showContainerInstallConfirmation = false

  var body: some View {
    HStack(spacing: 32) {
      VStack(alignment: .leading, spacing: 20) {
        Text("Poke PC")
          .font(.system(size: 44, weight: .bold, design: .rounded))

        Text("Secure, isolated AI runtime on your Mac. No Docker setup, no terminal required.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          Tag(text: "Ship Faster")
          Tag(text: "Approve Once")
          Tag(text: "Always Ready")
        }

        Text("Credentials file")
          .font(.headline)
          .padding(.top, 8)

        Text(appState.credentialsPath.isEmpty ? "Resolving path..." : appState.credentialsPath)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Text(appState.authMessage)
          .font(.footnote)
          .foregroundStyle(appState.credentialsPresent ? .green : .orange)

        if !appState.lastErrorMessage.isEmpty {
          Text(appState.lastErrorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }

      Spacer(minLength: 24)

      VStack(alignment: .leading, spacing: 18) {
        Text("Set Up")
          .font(.title2.weight(.semibold))

        Toggle("Enable command notifications", isOn: $appState.notificationsEnabled)

        if appState.isBusy {
          ProgressView(appState.statusMessage)
            .progressViewStyle(.linear)
        }

        if !appState.containerCLIInstalled {
          VStack(alignment: .leading, spacing: 8) {
            Text("Apple Container CLI is required")
              .font(.subheadline.weight(.semibold))
            Text(appState.awaitingContainerSetup
              ? "Installer opened. Finish installation, then refresh setup status or wait for automatic detection."
              : "Install it to run your isolated runtime.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Button("Install Apple Container CLI") {
              showContainerInstallConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isBusy)

            Button("Refresh Setup Status") {
              Task { await runtimeManager.refreshContainerCLIStatus() }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isBusy)
          }
          .padding(12)
          .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }

        if appState.authRequired {
          Button("Continue in Browser") {
            Task { await runtimeManager.startNativeLogin() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(appState.isBusy)

          Button("Copy Login Link") {
            Task { await runtimeManager.copyLoginLink() }
          }
          .buttonStyle(.bordered)
          .disabled(appState.loginUrl.isEmpty || appState.isBusy)

          if !appState.loginCode.isEmpty {
            Text("Approval code: \(appState.loginCode)")
              .font(.footnote.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Text("Your Poke login, runtime setup, and health checks happen automatically.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(width: 360)
      .padding(24)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    .padding(36)
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

private struct Tag: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.footnote.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.08), in: Capsule())
  }
}
