import Foundation
import AppKit

struct PokeLoginCode: Sendable {
  let deviceCode: String
  let userCode: String
  let loginURL: URL
}

enum PokeLoginError: LocalizedError {
  case invalidResponse
  case loginCodeExpired
  case loginCodeInvalid
  case timedOut

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Unexpected response from Poke login service."
    case .loginCodeExpired:
      return "Login code expired."
    case .loginCodeInvalid:
      return "Login code is invalid."
    case .timedOut:
      return "Login timed out before approval."
    }
  }
}

actor PokeCredentialsService {
  private let apiBaseURL = URL(string: "https://poke.com/api/v1")!
  private let frontendBaseURL = URL(string: "https://poke.com")!

  private struct CredentialsPayload: Decodable {
    let token: String
  }

  func credentialsPath() -> URL {
    AppPaths.pokeCredentials
  }

  func credentialsExist() -> Bool {
    FileManager.default.fileExists(atPath: AppPaths.pokeCredentials.path)
  }

  func loadTokenFromCredentials() -> String? {
    do {
      let data = try Data(contentsOf: credentialsPath())
      let payload = try JSONDecoder().decode(CredentialsPayload.self, from: data)
      return payload.token
    } catch {
      return nil
    }
  }

  func tokenNeedsReauthentication() async -> Bool {
    guard let token = loadTokenFromCredentials() else {
      return true
    }

    do {
      var request = URLRequest(url: apiBaseURL.appending(path: "user/profile"))
      request.httpMethod = "GET"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return true
      }

      if http.statusCode == 200 {
        return false
      }

      if http.statusCode == 401 || http.statusCode == 403 {
        return true
      }

      return false
    } catch {
      // Network or transient API errors should not force auth re-prompt.
      return false
    }
  }

  func ensureRuntimeCredentialsMirror() throws {
    try AppPaths.ensureDirectories()

    guard credentialsExist() else {
      throw NSError(
        domain: "PokeCredentialsService",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Poke credentials not found at \(AppPaths.pokeCredentials.path)"]
      )
    }

    let source = AppPaths.pokeCredentials
    let destination = AppPaths.runtimePokeCredentials

    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }

  func startDeviceLogin() async throws -> PokeLoginCode {
    var request = URLRequest(url: apiBaseURL.appending(path: "cli-auth/code"))
    request.httpMethod = "POST"

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw PokeLoginError.invalidResponse
    }

    struct Payload: Decodable {
      let deviceCode: String
      let userCode: String
    }

    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let loginURL = frontendBaseURL
      .appending(path: "device")
      .appending(queryItems: [URLQueryItem(name: "code", value: payload.userCode)])

    return PokeLoginCode(deviceCode: payload.deviceCode, userCode: payload.userCode, loginURL: loginURL)
  }

  func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  func copyLoginLink(_ url: URL, userCode: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("\(url.absoluteString)\nCode: \(userCode)", forType: .string)
  }

  func pollLogin(deviceCode: String, timeoutSeconds: TimeInterval = 300, pollIntervalSeconds: TimeInterval = 2) async throws -> String {
    let deadline = Date().addingTimeInterval(timeoutSeconds)

    struct PollResponse: Decodable {
      let status: String
      let token: String?
    }

    while Date() < deadline {
      try await Task.sleep(for: .milliseconds(Int64(pollIntervalSeconds * 1000)))

      let pollURL = apiBaseURL.appending(path: "cli-auth/poll").appending(path: deviceCode)
      let (data, response) = try await URLSession.shared.data(from: pollURL)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw PokeLoginError.invalidResponse
      }

      let payload = try JSONDecoder().decode(PollResponse.self, from: data)
      switch payload.status {
      case "authenticated":
        guard let token = payload.token else {
          throw PokeLoginError.invalidResponse
        }
        try saveToken(token)
        return token
      case "expired":
        throw PokeLoginError.loginCodeExpired
      case "invalid":
        throw PokeLoginError.loginCodeInvalid
      default:
        continue
      }
    }

    throw PokeLoginError.timedOut
  }

  private func saveToken(_ token: String) throws {
    let path = credentialsPath()
    let dir = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let payload = ["token": token]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    try data.write(to: path, options: [.atomic])

    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path.path)
  }
}
