import Foundation

#if canImport(Containerization)
import Containerization
import ContainerizationOCI
#endif

enum RuntimeServiceFactory {
  static func makeDefault() -> any RuntimeService {
    return ContainerizationRuntimeService()
  }
}

enum RuntimeBackend: String, Sendable {
  case appleContainer = "Apple Container"
}

protocol RuntimeService: Sendable {
  func backendName() async -> String
  func hasContainerCLI() async -> Bool
  func readRuntimeLogs(maxLines: Int) async throws -> [String]
  func checkRuntimeHealth() async throws -> Bool
  func ensureReady(credentialsPath: URL, report: @Sendable (String) -> Void) async throws
  func start(
    credentialsPath: URL,
    notificationsEnabled: Bool,
    report: @Sendable (String) -> Void
  ) async throws
  func stop(report: @Sendable (String) -> Void) async throws
}

actor ContainerizationRuntimeService: RuntimeService {
  private let image = "ghcr.io/calganaygun/poke-pc:latest"
  private let containerName = "poke-pc-native"
  private let mcpPort = "3000"

  private struct ContainerInspectItem: Decodable {
    let status: String
  }

  func backendName() async -> String {
    RuntimeBackend.appleContainer.rawValue
  }

  func hasContainerCLI() async -> Bool {
    await Shell.commandExists("container")
  }

  func readRuntimeLogs(maxLines: Int) async throws -> [String] {
    let result = try await Shell.run(
      "container",
      arguments: ["logs", "-n", "\(maxLines)", containerName],
      allowFailure: true
    )

    if result.exitCode != 0 {
      let details = result.stderr.isEmpty ? result.stdout : result.stderr
      throw ShellError.commandFailed(
        command: "container logs --tail \(maxLines) \(containerName)",
        code: result.exitCode,
        message: details
      )
    }

    let combinedOutput = [result.stdout, result.stderr]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    return combinedOutput
      .split(whereSeparator: \ .isNewline)
      .map(String.init)
  }

  func checkRuntimeHealth() async throws -> Bool {
    let inspectResult = try await Shell.run("container", arguments: ["inspect", containerName], allowFailure: true)
    if inspectResult.exitCode != 0 {
      return false
    }

    let inspectData = Data(inspectResult.stdout.utf8)
    let runningFromInspect: Bool
    if let decoded = try? JSONDecoder().decode([ContainerInspectItem].self, from: inspectData) {
      runningFromInspect = decoded.first?.status.lowercased() == "running"
    } else {
      let normalized = "\(inspectResult.stdout)\n\(inspectResult.stderr)".lowercased()
      runningFromInspect = normalized.contains("\"status\":\"running\"")
        || normalized.contains("\"status\" : \"running\"")
    }

    if !runningFromInspect {
      return false
    }

    let nodeProbe = "require('http').get('http://127.0.0.1:\(mcpPort)/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
    let probeResult = try await Shell.run(
      "container",
      arguments: ["exec", containerName, "node", "-e", nodeProbe],
      allowFailure: true
    )

    return probeResult.exitCode == 0
  }

  func ensureReady(credentialsPath: URL, report: @Sendable (String) -> Void) async throws {
    guard FileManager.default.fileExists(atPath: credentialsPath.path) else {
      throw NSError(
        domain: "ContainerizationRuntimeService",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "Missing Poke credentials at \(credentialsPath.path)"]
      )
    }
    report("Found credentials file at \(credentialsPath.path)")

    guard await hasContainerCLI() else {
      throw NSError(
        domain: "ContainerizationRuntimeService",
        code: 2002,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Apple 'container' CLI is required. Install it and retry.\n\n"
            + "Install via Homebrew:\n"
            + "brew install --cask container\n\n"
            + "Alternative installer:\n"
            + "https://github.com/apple/container/releases"
        ]
      )
    }
    report("Apple container CLI is available")

    try await ensureContainerSystemStarted(report: report)

    try AppPaths.ensureDirectories()
    report("Ensured runtime directories at \(AppPaths.runtimeStateRoot.path)")

#if canImport(Containerization)
    _ = ImageStore()
    report("Containerization framework is available")
#endif
  }

  func start(
    credentialsPath: URL,
    notificationsEnabled: Bool,
    report: @Sendable (String) -> Void
  ) async throws {
    try AppPaths.ensureDirectories()
    try mirrorCredentials(from: credentialsPath)
    report("Mirrored credentials into runtime config")
    try await runAppleContainerFlow(notificationsEnabled: notificationsEnabled, report: report)
  }

  func stop(report: @Sendable (String) -> Void) async throws {
    report("Stopping container \(containerName)")
    _ = try await Shell.run("container", arguments: ["stop", containerName], allowFailure: true)
    report("Removing container \(containerName)")
    _ = try await Shell.run("container", arguments: ["rm", containerName], allowFailure: true)
  }

  private func mirrorCredentials(from source: URL) throws {
    let destination = AppPaths.runtimePokeCredentials
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private func runAppleContainerFlow(
    notificationsEnabled: Bool,
    report: @Sendable (String) -> Void
  ) async throws {
    try await ensureContainerSystemStarted(report: report)

    report("Cleaning previous container if it exists")
    _ = try await Shell.run("container", arguments: ["stop", containerName], allowFailure: true)
    _ = try await Shell.run("container", arguments: ["rm", containerName], allowFailure: true)

    report("Pulling runtime image: \(image)")
    _ = try await Shell.run("container", arguments: ["image", "pull", image], allowFailure: true)
    report("Image pull completed")

    let args = [
      "run",
      "--detach",
      "--name", containerName,
      "--dns", "1.1.1.1",
      "--dns", "8.8.8.8",
      "--env", "POKE_TUNNEL_NAME=poke-pc",
      "--env", "MCP_PUBLIC_URL=http://127.0.0.1:3000/mcp",
      "--env", "POKE_PC_AUTOREGISTER_WEBHOOK=\(notificationsEnabled ? "true" : "false")",
      "--mount", "type=bind,source=\(AppPaths.runtimeStateRoot.path),target=/root/poke-pc",
      "--mount", "type=bind,source=\(AppPaths.runtimePokeConfigDir.path),target=/root/.config/poke",
      image
    ]

    report("Starting isolated runtime container")
    let runResult = try await Shell.run("container", arguments: args, allowFailure: true)
    if runResult.exitCode != 0 {
      let output = runResult.stderr.isEmpty ? runResult.stdout : runResult.stderr
      let normalized = output.lowercased()

      if normalized.contains("default kernel not configured") {
        report("Default container kernel is not configured. Installing recommended kernel")
        try await configureRecommendedKernel(report: report)
        report("Retrying container start after kernel setup")

        let retryResult = try await Shell.run("container", arguments: args, allowFailure: true)
        if retryResult.exitCode != 0 {
          let retryOutput = retryResult.stderr.isEmpty ? retryResult.stdout : retryResult.stderr
          throw ShellError.commandFailed(
            command: (["container"] + args).joined(separator: " "),
            code: retryResult.exitCode,
            message: retryOutput
          )
        }
      } else {
        throw ShellError.commandFailed(
          command: (["container"] + args).joined(separator: " "),
          code: runResult.exitCode,
          message: output
        )
      }
    }

    try await verifyContainerDNS(report: report)
    report("Container start command finished")
  }

  private func verifyContainerDNS(report: @Sendable (String) -> Void) async throws {
    report("Validating container DNS resolution")

    let dnsProbe = "require('dns').lookup('poke.com', err => process.exit(err ? 1 : 0))"
    let dnsResult = try await Shell.run(
      "container",
      arguments: ["exec", containerName, "node", "-e", dnsProbe],
      allowFailure: true
    )

    if dnsResult.exitCode != 0 {
      let details = dnsResult.stderr.isEmpty ? dnsResult.stdout : dnsResult.stderr
      throw NSError(
        domain: "ContainerizationRuntimeService",
        code: 2005,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Container DNS resolution failed (poke.com). This usually causes EAI_AGAIN network errors.\n\nTried DNS servers: 1.1.1.1, 8.8.8.8\n\n\(details)"
        ]
      )
    }

    report("Container DNS is working")
  }

  private func configureRecommendedKernel(report: @Sendable (String) -> Void) async throws {
    let result = try await Shell.run(
      "container",
      arguments: ["system", "kernel", "set", "--recommended"],
      allowFailure: true
    )

    if result.exitCode != 0 {
      let details = result.stderr.isEmpty ? result.stdout : result.stderr
      throw NSError(
        domain: "ContainerizationRuntimeService",
        code: 2004,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not configure the default container kernel automatically. Run this once in Terminal:\ncontainer system kernel set --recommended\n\n\(details)"
        ]
      )
    }

    report("Recommended container kernel configured")
  }

  private func ensureContainerSystemStarted(report: @Sendable (String) -> Void) async throws {
    report("Checking Apple container system service")

    let statusResult = try await Shell.run("container", arguments: ["system", "status"], allowFailure: true)
    let statusText = "\(statusResult.stdout)\n\(statusResult.stderr)".lowercased()
    let looksStopped = statusText.contains("not running") || statusText.contains("stopped") || statusResult.exitCode != 0

    if !looksStopped {
      report("Apple container system service is running")
      return
    }

    report("Apple container system service is not running, starting it")
    let startResult = try await Shell.run(
      "container",
      arguments: ["system", "start", "--enable-kernel-install", "--timeout", "120"],
      allowFailure: true
    )

    if startResult.exitCode == 0 {
      report("Apple container system service started")
      return
    }

    let details = startResult.stderr.isEmpty ? startResult.stdout : startResult.stderr
    throw NSError(
      domain: "ContainerizationRuntimeService",
      code: 2003,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Apple container system service is not running. Tried non-interactive start with 'container system start --enable-kernel-install --timeout 120' but it failed.\n\nRun this once in Terminal and approve prompts if asked:\ncontainer system start\n\n\(details)"
      ]
    )
  }

}
