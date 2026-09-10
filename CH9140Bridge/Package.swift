// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CH9140Bridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CH9140Core", targets: ["CH9140Core"]),
        .executable(name: "CH9140Bridge", targets: ["CH9140Bridge"])
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
            name: "CH9140Bridge",
            dependencies: [
                "CH9140Core",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/CH9140Bridge"
        ),
        .executableTarget(
            name: "CH9140SelfTest",
            dependencies: ["CH9140Core"],
            path: "Sources/CH9140SelfTest"
        )
    ]
)
