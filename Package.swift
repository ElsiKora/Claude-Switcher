// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ClaudeSwitcher",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
    ],
    targets: [
        // The app itself is built by ClaudeSwitcher.xcodeproj (project.yml),
        // which App Intents need; this package holds its core and the tests.
        .target(name: "SwitcherCore", swiftSettings: strict),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
