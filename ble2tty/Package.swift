// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ble2tty",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CH9140Core", targets: ["CH9140Core"]),
        .executable(name: "BLE2TTY", targets: ["BLE2TTY"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "CH9140Core",
            path: "Sources/CH9140Core"
        ),
        .executableTarget(
            name: "BLE2TTY",
            dependencies: [
                "CH9140Core",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/BLE2TTY"
        ),
        .executableTarget(
            name: "CH9140SelfTest",
            dependencies: ["CH9140Core"],
            path: "Sources/CH9140SelfTest"
        )
    ]
)
