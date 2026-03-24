import Foundation

struct ShellResult: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

enum ShellError: LocalizedError {
  case executableNotFound(String)
  case commandFailed(command: String, code: Int32, message: String)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let executable):
      return "Command not found: \(executable)"
    case .commandFailed(let command, let code, let message):
      return "Command failed (\(code)): \(command)\n\(message)"
    }
  }
}

enum Shell {
  private static let defaultSearchPaths = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/opt/container/bin"
  ]

  private static let containerExecutableCandidates = [
    "/opt/homebrew/bin/container",
    "/usr/local/bin/container",
    "/usr/bin/container",
    "/bin/container",
    "/opt/container/bin/container"
  ]

  static func run(
    _ command: String,
    arguments: [String] = [],
    currentDirectory: URL? = nil,
    environment: [String: String] = [:],
    allowFailure: Bool = false
  ) async throws -> ShellResult {
    guard let executable = resolveExecutable(command, environment: environment) else {
      throw ShellError.executableNotFound(command)
    }

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    if let currentDirectory {
      process.currentDirectoryURL = currentDirectory
    }

    process.environment = mergedEnvironment(with: environment)

    return try await withCheckedThrowingContinuation { continuation in
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: ShellError.executableNotFound(command))
        return
      }

      process.terminationHandler = { finishedProcess in
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let result = ShellResult(exitCode: finishedProcess.terminationStatus, stdout: stdout, stderr: stderr)

        if finishedProcess.terminationStatus != 0 && !allowFailure {
          continuation.resume(
            throwing: ShellError.commandFailed(
              command: ([command] + arguments).joined(separator: " "),
              code: finishedProcess.terminationStatus,
              message: stderr.isEmpty ? stdout : stderr
            )
          )
        } else {
          continuation.resume(returning: result)
        }
      }
    }
  }

  static func commandExists(_ command: String) async -> Bool {
    if command.contains("/") {
      return FileManager.default.isExecutableFile(atPath: command)
    }

    return resolveExecutable(command, environment: [:]) != nil
  }

  private static func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment

    let existingPath = env["PATH"] ?? ""
    let existingParts = Set(existingPath.split(separator: ":").map(String.init))
    let missingPaths = defaultSearchPaths.filter { !existingParts.contains($0) }
    let pathSegments = (existingPath.split(separator: ":").map(String.init) + missingPaths)
    env["PATH"] = pathSegments.joined(separator: ":")

    for (key, value) in overrides {
      env[key] = value
    }

    return env
  }

  private static func resolveExecutable(_ command: String, environment: [String: String]) -> String? {
    if command.contains("/") {
      return FileManager.default.isExecutableFile(atPath: command) ? command : nil
    }

    if command == "container" {
      for candidate in containerExecutableCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    let env = mergedEnvironment(with: environment)
    let pathValue = env["PATH"] ?? ""
    for path in pathValue.split(separator: ":") {
      let candidate = String(path) + "/" + command
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    return nil
  }
}
