import Foundation
import SwiftUI

actor RuntimeManager {
  private weak var appState: AppState?
  private let service: any RuntimeService
  private let credentialsService: PokeCredentialsService
  private let containerInstaller = ContainerCLIInstaller()
  private var healthTask: Task<Void, Never>?
  private var containerInstallWatchTask: Task<Void, Never>?
  private var containerLogTask: Task<Void, Never>?
  private var previousContainerLogLines: [String] = []
  private var lastContainerLogPollError: String?

  init(
    service: any RuntimeService = RuntimeServiceFactory.makeDefault(),
    credentialsService: PokeCredentialsService = PokeCredentialsService()
  ) {
    self.service = service
    self.credentialsService = credentialsService
  }

  nonisolated func bind(appState: AppState) {
    Task { await setAppState(appState) }
  }

  func bootstrap() async {
    await publishBusy(true)
    await setError("")
    await refreshCredentialsStatus()
    await refreshContainerCLIStatus()

    let backend = await service.backendName()
    await publishBackend(backend)
    await appendLog("Detected runtime backend: \(backend)")

    let runtimeAlreadyRunning = (try? await service.checkRuntimeHealth()) ?? false
    if runtimeAlreadyRunning {
      await publish(status: .healthy, message: "Poke PC runtime is already running")
      await setHealthSummary("Detected running runtime on app launch")
      await finishOnboarding()
      await appendLog("Detected existing running runtime. Opening dashboard.")
      await startHealthMonitor()
      await startContainerLogStream()
      await publishBusy(false)
      return
    }

    let state = appState
    let hasCredentials = await MainActor.run { state?.credentialsPresent ?? false }
    if !hasCredentials {
      await showOnboarding()
      await appendLog("No credentials file found. Starting native Poke login flow.")
      await startNativeLogin(autoTriggered: true)
    } else {
      let authRequired = await MainActor.run { state?.authRequired ?? true }
      if authRequired {
        await showOnboarding()
        await appendLog("Credentials exist but require reauthentication.")
      } else {
        await finishOnboarding()
        await appendLog("Credentials found and verified. Skipping login screen.")
      }
    }

    await publishBusy(false)
  }

  func refreshContainerCLIStatus() async {
    let installed = await service.hasContainerCLI()
    await setContainerCLIInstalled(installed)

    if installed {
      containerInstallWatchTask?.cancel()
      containerInstallWatchTask = nil
      await setAwaitingContainerSetup(false)
      await setError("")
      await appendLog("Apple container CLI detected")
    } else {
      let awaiting = await isAwaitingContainerSetup()
      await appendLog("Apple container CLI is not installed")
      if !awaiting {
        await setError("Apple container CLI is required. Install it to continue.")
      }
    }
  }

  func installContainerCLI() async {
    await publishBusy(true)
    await setError("")
    await appendLog("Starting Apple container CLI installer flow")

    do {
      let packageURL = try await containerInstaller.installLatestPackage(report: runtimeReporter())
      await appendLog("Installer opened from \(packageURL.path)")
      await setAwaitingContainerSetup(true)
      await setAuthMessage("Container CLI installer opened. Finishing install... checking every few seconds.")
      await setError("")
      await startContainerInstallWatch()
    } catch {
      await appendLog("Container CLI install failed: \(error.localizedDescription)")
      await setAwaitingContainerSetup(false)
      await setError(error.localizedDescription)
    }

    await refreshContainerCLIStatus()
    await publishBusy(false)
  }

  func refreshCredentialsStatus() async {
    let credentialsPath = await credentialsService.credentialsPath()
    let exists = await credentialsService.credentialsExist()
    let reauthRequired = exists ? await credentialsService.tokenNeedsReauthentication() : true
    let state = appState

    await MainActor.run {
      state?.credentialsPath = credentialsPath.path
      state?.credentialsPresent = exists
      state?.authRequired = reauthRequired
      state?.isAuthenticated = exists && !reauthRequired
      if !exists {
        state?.authMessage = "Poke credentials not found"
      } else if reauthRequired {
        state?.authMessage = "Credentials need re-login (401/403)."
      } else {
        state?.authMessage = "Poke credentials verified"
      }
      if exists {
        state?.loginUrl = ""
        state?.loginCode = ""
      }
    }
  }

  func startNativeLogin(autoTriggered: Bool = false) async {
    await publishBusy(true)
    await setError("")
    await appendLog("Starting native Poke browser login")

    do {
      let loginCode = try await credentialsService.startDeviceLogin()
      await setLoginLink(url: loginCode.loginURL.absoluteString, code: loginCode.userCode)

      await appendLog("Opening browser for login approval")
      await openLoginURL(loginCode.loginURL)
      await setAuthMessage(autoTriggered ? "Approve login in browser. Waiting for confirmation..." : "Approve login in browser.")

      _ = try await credentialsService.pollLogin(deviceCode: loginCode.deviceCode)
      await refreshCredentialsStatus()
      await setAuthMessage("Login approved and credentials saved.")
      await setAuthRequired(false)
      await appendLog("Poke login completed successfully")
      await finishOnboarding()
    } catch {
      await appendLog("Native login failed: \(error.localizedDescription)")
      await setAuthMessage("Login not completed. You can reopen the browser link or copy it.")
      await setError(error.localizedDescription)
    }

    await publishBusy(false)
  }

  func copyLoginLink() async {
    let state = appState
    let tuple = await MainActor.run { () -> (String, String) in
      (state?.loginUrl ?? "", state?.loginCode ?? "")
    }

    guard let url = URL(string: tuple.0), !tuple.0.isEmpty else {
      await setAuthMessage("No login link available to copy yet.")
      return
    }

    await credentialsService.copyLoginLink(url, userCode: tuple.1)
    await setAuthMessage("Login link and code copied to clipboard.")
  }

  func openSavedLoginLink() async {
    let state = appState
    let link = await MainActor.run { state?.loginUrl ?? "" }
    guard let url = URL(string: link), !link.isEmpty else {
      await setAuthMessage("No login link available yet.")
      return
    }

    await openLoginURL(url)
    await setAuthMessage("Browser opened for login approval.")
  }

  func startRuntime() async {
    await publishBusy(true)
    await setError("")
    await publish(status: .preparing, message: "Checking environment")
    await appendLog("Runtime start requested")
    do {
      await refreshCredentialsStatus()
      await refreshContainerCLIStatus()

      let state = appState
      let authRequired = await MainActor.run { state?.authRequired ?? true }
      if authRequired {
        throw NSError(
          domain: "RuntimeManager",
          code: 3101,
          userInfo: [NSLocalizedDescriptionKey: "Authentication required. Sign in with browser first."]
        )
      }

      let hasContainerCLI = await MainActor.run { state?.containerCLIInstalled ?? false }
      if !hasContainerCLI {
        throw NSError(
          domain: "RuntimeManager",
          code: 3102,
          userInfo: [NSLocalizedDescriptionKey: "Apple container CLI is required. Install it first."]
        )
      }

      let credentialsPath = await credentialsService.credentialsPath()
      try await service.ensureReady(credentialsPath: credentialsPath, report: runtimeReporter())

      await publish(status: .pullingImage(progress: nil), message: "Downloading runtime image (this may take a few minutes)")

      await publish(status: .creatingContainer, message: "Creating isolated Linux runtime")
      let notificationsEnabled = await MainActor.run { state?.notificationsEnabled ?? true }
      try await service.start(
        credentialsPath: credentialsPath,
        notificationsEnabled: notificationsEnabled,
        report: runtimeReporter()
      )

      await publish(status: .healthy, message: "Poke PC runtime is running")
      await appendLog("Runtime started successfully")
      await startHealthMonitor()
      await startContainerLogStream()
    } catch {
      await publish(status: .failed(reason: error.localizedDescription), message: "Failed to start runtime")
      await appendLog("Runtime start failed: \(error.localizedDescription)")
      await setError(error.localizedDescription)
      stopContainerLogStream()
    }
    await publishBusy(false)
  }

  func stopRuntime() async {
    await publishBusy(true)
    await publish(status: .stopping, message: "Stopping runtime")
    healthTask?.cancel()
    healthTask = nil
    stopContainerLogStream()

    do {
      try await service.stop(report: runtimeReporter())
      await publish(status: .idle, message: "Runtime stopped")
      await appendLog("Runtime stopped")
      await setHealthSummary("Health monitor stopped")
    } catch {
      await publish(status: .degraded(reason: error.localizedDescription), message: "Runtime could not stop cleanly")
      await appendLog("Runtime stop encountered an error: \(error.localizedDescription)")
      await setError(error.localizedDescription)
    }

    await publishBusy(false)
  }

  private func setAppState(_ appState: AppState) {
    self.appState = appState
  }

  private func startHealthMonitor() async {
    healthTask?.cancel()

    healthTask = Task { [weak self] in
      guard let self else { return }
      var failureCount = 0

      while !Task.isCancelled {
        do {
          let ok = try await self.service.checkRuntimeHealth()
          if ok {
            await self.setHealthSummary("Healthy at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))")
            let status = await self.currentRuntimeStatus()
            if case .degraded = status {
              await self.publish(status: .healthy, message: "Poke PC runtime is running")
            }
            failureCount = 0
          } else {
            failureCount += 1
            await self.setHealthSummary("Runtime is not healthy yet")
          }
        } catch {
          failureCount += 1
          await self.setHealthSummary("Health check failed: \(error.localizedDescription)")
        }

        if failureCount >= 3 {
          await self.publish(status: .degraded(reason: "Health checks are failing"), message: "Runtime degraded: health endpoint unreachable")
        }

        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func startContainerInstallWatch() async {
    containerInstallWatchTask?.cancel()
    containerInstallWatchTask = Task { [weak self] in
      guard let self else { return }
      await self.runContainerInstallWatchLoop()
    }
  }

  private func startContainerLogStream() async {
    stopContainerLogStream()
    previousContainerLogLines = []
    lastContainerLogPollError = nil

    containerLogTask = Task { [weak self] in
      guard let self else { return }
      await self.runContainerLogStreamLoop()
    }
  }

  private func runContainerLogStreamLoop() async {
    while !Task.isCancelled {
      do {
        let lines = try await service.readRuntimeLogs(maxLines: 200)
        let newLines = newContainerLogLines(
          previous: previousContainerLogLines,
          current: lines
        )
        previousContainerLogLines = lines
        lastContainerLogPollError = nil

        for line in newLines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          await appendLog("[container] \(line)")
        }
      } catch {
        let message = error.localizedDescription
        if lastContainerLogPollError != message {
          lastContainerLogPollError = message
          await appendLog("Container log stream warning: \(message)")
        }
      }

      try? await Task.sleep(for: .seconds(2))
    }
  }

  private func stopContainerLogStream() {
    containerLogTask?.cancel()
    containerLogTask = nil
    previousContainerLogLines = []
    lastContainerLogPollError = nil
  }

  private func newContainerLogLines(previous: [String], current: [String]) -> [String] {
    guard !current.isEmpty else {
      return []
    }

    let maxOverlap = min(previous.count, current.count)
    if maxOverlap == 0 {
      return current
    }

    for overlap in stride(from: maxOverlap, through: 0, by: -1) {
      let previousTail = Array(previous.suffix(overlap))
      let currentHead = Array(current.prefix(overlap))
      if previousTail == currentHead {
        return Array(current.dropFirst(overlap))
      }
    }

    return current
  }

  private func runContainerInstallWatchLoop() async {
    let timeoutAt = Date().addingTimeInterval(300)

    while Date() < timeoutAt {
      try? await Task.sleep(for: .seconds(4))
      if Task.isCancelled {
        return
      }

      let installed = await service.hasContainerCLI()
      await setContainerCLIInstalled(installed)
      if installed {
        await setAwaitingContainerSetup(false)
        await setError("")
        await setAuthMessage("Setup complete. Apple container CLI detected.")
        await appendLog("Apple container CLI detected after installer run")
        return
      }
    }

    await setAwaitingContainerSetup(false)
    await setAuthMessage("Still waiting for installation. Use Refresh Setup Status after installer completes.")
    await appendLog("Container CLI auto-check timed out")
  }

  private func publish(status: RuntimeStatus, message: String) async {
    let state = appState
    await MainActor.run {
      state?.runtimeStatus = status
      state?.statusMessage = message
    }
  }

  private func publishBackend(_ backendName: String) async {
    let state = appState
    await MainActor.run {
      state?.backendName = backendName
    }
  }

  private func publishBusy(_ value: Bool) async {
    let state = appState
    await MainActor.run {
      state?.isBusy = value
    }
  }

  private func appendLog(_ message: String) async {
    let state = appState
    await MainActor.run {
      state?.appendLog(message)
    }
  }

  private func setHealthSummary(_ message: String) async {
    let state = appState
    await MainActor.run {
      state?.lastHealthSummary = message
    }
  }

  private func currentRuntimeStatus() async -> RuntimeStatus {
    let state = appState
    return await MainActor.run {
      state?.runtimeStatus ?? .idle
    }
  }

  private func setAuthMessage(_ message: String) async {
    let state = appState
    await MainActor.run {
      state?.authMessage = message
    }
  }

  private func setAuthRequired(_ value: Bool) async {
    let state = appState
    await MainActor.run {
      state?.authRequired = value
      state?.isAuthenticated = !value
    }
  }

  private func setError(_ message: String) async {
    let state = appState
    await MainActor.run {
      state?.lastErrorMessage = message
    }
  }

  private func setContainerCLIInstalled(_ value: Bool) async {
    let state = appState
    await MainActor.run {
      state?.containerCLIInstalled = value
    }
  }

  private func setAwaitingContainerSetup(_ value: Bool) async {
    let state = appState
    await MainActor.run {
      state?.awaitingContainerSetup = value
    }
  }

  private func isAwaitingContainerSetup() async -> Bool {
    let state = appState
    return await MainActor.run {
      state?.awaitingContainerSetup ?? false
    }
  }

  private func finishOnboarding() async {
    let state = appState
    await MainActor.run {
      state?.finishOnboarding()
    }
  }

  private func showOnboarding() async {
    let state = appState
    await MainActor.run {
      state?.showOnboarding()
    }
  }

  private nonisolated func runtimeReporter() -> @Sendable (String) -> Void {
    { message in
      Task {
        await self.appendLog(message)
      }
    }
  }

  private func setLoginLink(url: String, code: String) async {
    let state = appState
    await MainActor.run {
      state?.loginUrl = url
      state?.loginCode = code
    }
  }

  private func openLoginURL(_ url: URL) async {
    await credentialsService.openInBrowser(url)
  }
}

private struct RuntimeManagerKey: EnvironmentKey {
  static let defaultValue = RuntimeManager()
}

extension EnvironmentValues {
  var runtimeManager: RuntimeManager {
    get { self[RuntimeManagerKey.self] }
    set { self[RuntimeManagerKey.self] = newValue }
  }
}

struct MockRuntimeService: RuntimeService {
  func backendName() async -> String {
    "Mock Backend"
  }

  func hasContainerCLI() async -> Bool {
    true
  }

  func readRuntimeLogs(maxLines: Int) async throws -> [String] {
    []
  }

  func checkRuntimeHealth() async throws -> Bool {
    true
  }

  func ensureReady(credentialsPath: URL, report: @Sendable (String) -> Void) async throws {
    report("Mock: validating environment")
    try await Task.sleep(for: .milliseconds(500))
  }

  func start(
    credentialsPath: URL,
    notificationsEnabled: Bool,
    report: @Sendable (String) -> Void
  ) async throws {
    report("Mock: starting runtime")
    try await Task.sleep(for: .milliseconds(900))
  }

  func stop(report: @Sendable (String) -> Void) async throws {
    report("Mock: stopping runtime")
    try await Task.sleep(for: .milliseconds(350))
  }
}
