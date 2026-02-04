// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imsg",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "IMsgCore", targets: ["IMsgCore"]),
        .executable(name: "imsg", targets: ["imsg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "IMsgCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
            ]
        ),
    .executableTarget(
        name: "imsg",
        dependencies: [
            "IMsgCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        exclude: [
            "Resources/Info.plist",
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/imsg/Resources/Info.plist",
            ])
        ]
    ),
        .testTarget(
            name: "IMsgCoreTests",
            dependencies: [
                "IMsgCore",
            ]
        ),
        .testTarget(
            name: "imsgTests",
            dependencies: [
                "imsg",
                "IMsgCore",
            ]
        ),
    ]
)
