import Foundation
import AppKit

actor ContainerCLIInstaller {
  private let latestReleaseAPI = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!

  func installLatestPackage(report: @Sendable (String) -> Void) async throws -> URL {
    report("Checking latest Apple container release")
    let pkgURL = try await latestPackageURL()
    report("Downloading installer package")
    let downloadedURL = try await downloadPackage(from: pkgURL)
    report("Opening installer")

    await MainActor.run {
      _ = NSWorkspace.shared.open(downloadedURL)
    }

    return downloadedURL
  }

  private func latestPackageURL() async throws -> URL {
    var request = URLRequest(url: latestReleaseAPI)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("PokePC", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw NSError(
        domain: "ContainerCLIInstaller",
        code: 4201,
        userInfo: [NSLocalizedDescriptionKey: "Could not read GitHub release metadata for Apple container CLI."]
      )
    }

    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".pkg") }),
          let pkgURL = URL(string: asset.browserDownloadURL)
    else {
      throw NSError(
        domain: "ContainerCLIInstaller",
        code: 4202,
        userInfo: [NSLocalizedDescriptionKey: "No .pkg installer asset was found in the latest Apple container release."]
      )
    }

    return pkgURL
  }

  private func downloadPackage(from remoteURL: URL) async throws -> URL {
    var request = URLRequest(url: remoteURL)
    request.setValue("PokePC", forHTTPHeaderField: "User-Agent")

    let (temporaryURL, response) = try await URLSession.shared.download(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw NSError(
        domain: "ContainerCLIInstaller",
        code: 4203,
        userInfo: [NSLocalizedDescriptionKey: "Failed to download the Apple container CLI package."]
      )
    }

    let downloadsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

    let fileName = remoteURL.lastPathComponent.isEmpty ? "container-latest.pkg" : remoteURL.lastPathComponent
    let destinationURL = downloadsDir.appendingPathComponent(fileName)

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    return destinationURL
  }
}

private struct GitHubRelease: Decodable {
  let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
  let name: String
  let browserDownloadURL: String

  enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
  }
}