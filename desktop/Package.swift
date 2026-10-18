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
                // Embeds the app's Info.plist in the binary too, so a bare debug build has the same bundle
                // identifier and name ("Mycroft Hands") as the app that scripts/build.sh assembles.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Sources/hands-desktop/Info.plist"]),
            ]
        ),
        .testTarget(name: "DesktopCoreTests", dependencies: ["DesktopCore"]),
    ]
)
