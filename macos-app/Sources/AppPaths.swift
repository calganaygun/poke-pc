import Foundation

enum AppPaths {
  static var homeDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
  }

  static var pokeCredentials: URL {
    homeDirectory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("poke", isDirectory: true)
      .appendingPathComponent("credentials.json", isDirectory: false)
  }

  static var appSupportRoot: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("PokePCNative", isDirectory: true)
  }

  static var runtimeStateRoot: URL {
    appSupportRoot.appendingPathComponent("runtime", isDirectory: true)
  }

  static var runtimePokeConfigDir: URL {
    runtimeStateRoot.appendingPathComponent("poke-config", isDirectory: true)
  }

  static var runtimePokeCredentials: URL {
    runtimePokeConfigDir.appendingPathComponent("credentials.json", isDirectory: false)
  }

  static func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeStateRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimePokeConfigDir, withIntermediateDirectories: true)
  }
}
