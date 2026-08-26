// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EC25Toolbox",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "EC25Toolbox", targets: ["EC25Toolbox"]),
        .executable(name: "EC25IKEHelper", targets: ["EC25IKEHelper"]),
        .executable(name: "EC25SystemHelper", targets: ["EC25SystemHelper"])
    ],
    targets: [
        .target(
            name: "EC25IKEHelperProtocol",
            path: "Sources/EC25IKEHelperProtocol"
        ),
        .target(
            name: "EC25SystemHelperProtocol",
            path: "Sources/EC25SystemHelperProtocol"
        ),
        .target(
            name: "CVoWiFiCrypto",
            path: "Sources/CVoWiFiCrypto",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "EC25Toolbox",
            dependencies: ["CVoWiFiCrypto", "EC25IKEHelperProtocol", "EC25SystemHelperProtocol"],
            path: "Sources/EC25Toolbox",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Charts"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "EC25IKEHelper",
            dependencies: ["EC25IKEHelperProtocol"],
            path: "Sources/EC25IKEHelper",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "EC25SystemHelper",
            dependencies: ["EC25SystemHelperProtocol"],
            path: "Sources/EC25SystemHelper",
            exclude: ["Info.plist", "ing.fuyaoskyrocket.ec25toolbox.system-helper.plist"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                // SMAppService requires an embedded Info.plist in the daemon
                // executable; SwiftPM does not generate one for executable
                // targets, so link it in directly.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/EC25SystemHelper/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "EC25ToolboxTests",
            dependencies: ["EC25Toolbox", "EC25SystemHelperProtocol"],
            path: "Tests/EC25ToolboxTests"
        )
    ]
)
