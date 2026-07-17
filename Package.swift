// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NimbusVTT",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NimbusVTT", targets: ["NimbusVTT"]),
    ],
    targets: [
        .executableTarget(
            name: "NimbusVTT",
            path: "app",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
