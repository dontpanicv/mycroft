// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hands-desktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesktopCore", targets: ["DesktopCore"]),
        .executable(name: "hands-desktop", targets: ["hands-desktop"]),
    ],
    targets: [
        .target(name: "DesktopCore"),
        .executableTarget(
            name: "hands-desktop",
            dependencies: ["DesktopCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embeds a bundle identifier and name in the binary, so the Accessibility list and the
                // permission dialog show "hands-desktop" under a stable identifier.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Sources/hands-desktop/Info.plist"]),
            ]
        ),
        .testTarget(name: "DesktopCoreTests", dependencies: ["DesktopCore"]),
    ]
)
