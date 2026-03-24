// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PokePCNative",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(
      name: "PokePCNative",
      targets: ["PokePCNative"]
    )
  ],
  targets: [
    .executableTarget(
      name: "PokePCNative",
      path: "Sources"
    )
  ]
)
