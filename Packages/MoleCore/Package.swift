// swift-tools-version:5.9
// MoleCore: Mole's engine (github.com/tw93/mole, GPL-3.0) ported to Swift for this app.
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "MoleCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoleCore", targets: ["MoleCore"]),
        .executable(name: "MoleCoreChecks", targets: ["MoleCoreChecks"]),
    ],
    targets: [
        .target(name: "MoleCore"),
        // Plain executable checks instead of XCTest, so the same suite runs with swiftc alone
        // (see Tools/check.sh) and under SwiftPM or Xcode.
        .executableTarget(name: "MoleCoreChecks", dependencies: ["MoleCore"]),
    ]
)
