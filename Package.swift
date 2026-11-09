// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MoneyApp",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "MoneyApp", targets: ["MoneyApp"])],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "MoneyCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "MoneyApp", dependencies: ["MoneyCore"]),
    .testTarget(name: "MoneyCoreTests", dependencies: ["MoneyCore"]),
  ]
)
