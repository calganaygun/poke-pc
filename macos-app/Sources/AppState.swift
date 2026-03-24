import Foundation

@MainActor
final class AppState: ObservableObject {
  enum LaunchStage: Equatable {
    case onboarding
    case dashboard
  }

  @Published var launchStage: LaunchStage = .onboarding
  @Published var isAuthenticated: Bool = false
  @Published var runtimeStatus: RuntimeStatus = .idle
  @Published var statusMessage: String = "Ready to set up Poke PC"
  @Published var notificationsEnabled: Bool = true
  @Published var backendName: String = "Detecting runtime backend"
  @Published var credentialsPath: String = ""
  @Published var credentialsPresent: Bool = false
  @Published var authRequired: Bool = true
  @Published var containerCLIInstalled: Bool = true
  @Published var awaitingContainerSetup: Bool = false
  @Published var authMessage: String = "Checking credentials"
  @Published var loginUrl: String = ""
  @Published var loginCode: String = ""
  @Published var isBusy: Bool = false
  @Published var lastErrorMessage: String = ""
  @Published var recentLogs: [String] = []
  @Published var lastHealthSummary: String = "Health not checked yet"

  var menuBarSymbol: String {
    switch runtimeStatus {
    case .healthy:
      return "bolt.circle.fill"
    case .failed, .degraded:
      return "exclamationmark.triangle.fill"
    case .preparing, .pullingImage, .creatingContainer, .booting, .stopping:
      return "arrow.triangle.2.circlepath.circle.fill"
    case .idle:
      return "bolt.circle"
    }
  }

  func finishOnboarding() {
    launchStage = .dashboard
  }

  func showOnboarding() {
    launchStage = .onboarding
  }

  func appendLog(_ text: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    recentLogs.append("[\(timestamp)] \(text)")
    if recentLogs.count > 300 {
      recentLogs.removeFirst(recentLogs.count - 300)
    }
  }
}
