import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.runtimeManager) private var runtimeManager
  @State private var selection: SidebarItem = .status

  enum SidebarItem: String, CaseIterable, Identifiable {
    case status
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
      switch self {
      case .status: return "Status"
      case .logs: return "Logs"
      case .settings: return "Settings"
      }
    }

    var symbol: String {
      switch self {
      case .status: return "heart.text.square"
      case .logs: return "text.alignleft"
      case .settings: return "slider.horizontal.3"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(SidebarItem.allCases, selection: $selection) { item in
        Label(item.title, systemImage: item.symbol)
          .tag(item)
      }
      .navigationTitle("Poke PC")
    } detail: {
      switch selection {
      case .status:
        StatusDetailView()
      case .logs:
        LogsDetailView()
      case .settings:
        SettingsDetailView()
      }
    }
  }
}

private struct StatusDetailView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.runtimeManager) private var runtimeManager
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
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Runtime Overview")
            .font(.largeTitle.weight(.semibold))
          Text(appState.statusMessage)
            .foregroundStyle(.secondary)
        }

        Spacer()

        StatusChip(status: appState.runtimeStatus)
      }

      HStack(spacing: 12) {
        if !appState.containerCLIInstalled {
          Button("Setup First") {
            showContainerInstallConfirmation = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(appState.isBusy)

          Button("Refresh Setup Status") {
            Task { await runtimeManager.refreshContainerCLIStatus() }
          }
          .buttonStyle(.bordered)
          .disabled(appState.isBusy)
        } else {
          if showStartButton {
            Button("Start") {
              Task { await runtimeManager.startRuntime() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isBusy)
          }

          if showStopButton {
            Button("Stop") {
              Task { await runtimeManager.stopRuntime() }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isBusy)
          }

          if showRefreshCredentialsButton {
            Button("Refresh Credentials") {
              Task { await runtimeManager.refreshCredentialsStatus() }
            }
            .buttonStyle(.bordered)
          }

          if appState.authRequired {
            Button("Sign In with Browser") {
              Task { await runtimeManager.startNativeLogin() }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isBusy)

            Button("Copy Login Link") {
              Task { await runtimeManager.copyLoginLink() }
            }
            .buttonStyle(.bordered)
            .disabled(appState.loginUrl.isEmpty)
          }
        }
      }

      if appState.isBusy {
        ProgressView(appState.statusMessage)
          .progressViewStyle(.linear)
      }

      if !appState.lastErrorMessage.isEmpty {
        Text(appState.lastErrorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }

      if !appState.containerCLIInstalled {
        VStack(alignment: .leading, spacing: 8) {
          Text("Setup required")
            .font(.headline)
            Text(appState.awaitingContainerSetup
              ? "Installer opened. Complete install, then refresh setup status or wait a few seconds for automatic detection."
              : "Apple Container CLI is missing. Complete setup first to unlock runtime controls.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          Button("Setup First") {
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
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Backend: \(appState.backendName)")
        Text("Credentials: \(appState.credentialsPresent ? "Available" : "Missing")")
        Text("Health: \(appState.lastHealthSummary)")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      RuntimeTimeline(status: appState.runtimeStatus)

      Spacer()
    }
    .padding(28)
    .background(Brand.panel, in: RoundedRectangle(cornerRadius: 20))
    .padding(20)
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

private struct LogsDetailView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Runtime Logs")
        .font(.title2.weight(.semibold))

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if appState.recentLogs.isEmpty {
            Text("No logs yet")
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(appState.recentLogs.enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
    .padding(24)
    .background(Brand.panel, in: RoundedRectangle(cornerRadius: 20))
    .padding(20)
  }
}

private struct SettingsDetailView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    Form {
      Section("Behavior") {
        Toggle("Enable command notifications", isOn: $appState.notificationsEnabled)
      }

      Section("Poke Credentials") {
        Text(appState.credentialsPath)
          .font(.system(.footnote, design: .monospaced))
        Text(appState.authMessage)
          .foregroundStyle(appState.credentialsPresent ? .green : .orange)
      }

      Section("Runtime") {
        Text("Backend: \(appState.backendName)")
        Text("Health: \(appState.lastHealthSummary)")
      }
    }
    .formStyle(.grouped)
    .padding(20)
  }
}

private struct StatusChip: View {
  let status: RuntimeStatus

  var body: some View {
    Text(status.title)
      .font(.callout.weight(.semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(chipColor.opacity(0.2), in: Capsule())
      .foregroundStyle(chipColor)
  }

  private var chipColor: Color {
    switch status {
    case .healthy:
      return .green
    case .failed, .degraded:
      return .red
    case .idle:
      return .gray
    default:
      return .orange
    }
  }
}

private struct RuntimeTimeline: View {
  let status: RuntimeStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Startup Pipeline")
        .font(.title3.weight(.semibold))

      pipelineRow(title: "Environment Check", active: status.isWorking || status == .healthy)
      pipelineRow(title: "Container Provisioning", active: status == .creatingContainer || status == .booting || status == .healthy)
      pipelineRow(title: "Service Boot", active: status == .booting || status == .healthy)
      pipelineRow(title: "Healthy", active: status == .healthy)
    }
  }

  private func pipelineRow(title: String, active: Bool) -> some View {
    HStack {
      Circle()
        .fill(active ? Color.green : Color.secondary.opacity(0.25))
        .frame(width: 10, height: 10)
      Text(title)
      Spacer()
    }
    .font(.body)
  }
}
