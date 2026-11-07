// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "LedgerAtlas",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "LedgerCore", targets: ["LedgerCore"]),
    .library(name: "MMImport", targets: ["MMImport"]),
    .library(name: "MMFixtures", targets: ["MMFixtures"]),
    .library(name: "LedgerAtlasMacUI", targets: ["LedgerAtlasMacUI"]),
    .executable(name: "mmctl", targets: ["mmctl"]),
    .executable(name: "LedgerAtlasMac", targets: ["LedgerAtlasMac"]),
  ],
  targets: [
    .target(
      name: "CSQLite",
      publicHeadersPath: "include",
      linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]
    ),
    .target(name: "LedgerCore"),
    .target(name: "LedgerAdapterSemantics", dependencies: ["LedgerCore"]),
    .target(
      name: "LedgerStore",
      dependencies: ["CSQLite", "LedgerCore", "LedgerAdapterSemantics"],
      linkerSettings: [.linkedFramework("Security")]),
    .target(
      name: "MMImport",
      dependencies: ["CSQLite", "LedgerCore", "LedgerStore", "LedgerAdapterSemantics"]),
    .target(name: "MMFixtures", dependencies: ["LedgerCore"]),
    .target(
      name: "LedgerAtlasMacUI", dependencies: ["MMImport", "LedgerStore", "CSQLite"],
      linkerSettings: [
        .linkedFramework("ImageIO"), .linkedFramework("LocalAuthentication"),
        .linkedFramework("Network"),
        .linkedFramework("UserNotifications"),
        .linkedFramework("Vision"),
      ]),
    .executableTarget(name: "mmctl", dependencies: ["LedgerCore", "MMImport"]),
    .executableTarget(
      name: "LedgerAtlasMac", dependencies: ["LedgerAtlasMacUI"],
      linkerSettings: [.linkedFramework("AppIntents")]),
    .testTarget(
      name: "LedgerCoreTests", dependencies: ["LedgerCore", "MMImport", "MMFixtures"],
      // The CSV golden file is read from disk by path.
      exclude: ["Exchange/Fixtures"]),
    .testTarget(
      name: "LedgerStoreTests",
      dependencies: ["CSQLite", "LedgerCore", "LedgerStore", "LedgerAdapterSemantics"]),
    .testTarget(
      name: "MMImportTests", dependencies: ["CSQLite", "LedgerCore", "LedgerStore", "MMImport"],
      // Read from disk by path, not bundled.
      exclude: ["Fixtures"]),
    .testTarget(name: "MMFixturesTests", dependencies: ["MMFixtures"]),
    .testTarget(
      name: "LedgerAtlasMacUITests",
      dependencies: ["CSQLite", "LedgerCore", "LedgerStore", "MMImport", "LedgerAtlasMacUI"]),
  ]
)
