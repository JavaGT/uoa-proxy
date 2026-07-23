// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UoAProxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UoAProxyCore", targets: ["UoAProxyCore"]),
        .executable(name: "uoa-proxyd", targets: ["uoa-proxyd"]),
        .executable(name: "uoa-proxy", targets: ["uoa-proxy"]),
        .executable(name: "uoa-proxy-helper", targets: ["uoa-proxy-helper"]),
        .executable(name: "uoa-proxy-supervisor", targets: ["uoa-proxy-supervisor"]),
        .executable(name: "UoAProxy", targets: ["UoAProxy"])
    ],
    targets: [
        .target(
            name: "UoAProxyCore",
            path: "Sources/UoAProxyCore"
        ),
        .executableTarget(
            name: "uoa-proxyd",
            dependencies: ["UoAProxyCore"],
            path: "Sources/uoa-proxyd"
        ),
        .executableTarget(
            name: "uoa-proxy",
            dependencies: ["UoAProxyCore"],
            path: "Sources/uoa-proxy"
        ),
        .executableTarget(
            name: "uoa-proxy-helper",
            path: "Sources/uoa-proxy-helper"
        ),
        .executableTarget(
            name: "uoa-proxy-supervisor",
            path: "Sources/uoa-proxy-supervisor"
        ),
        .executableTarget(
            name: "UoAProxy",
            dependencies: ["UoAProxyCore"],
            path: "Sources/UoAProxy"
        )
    ]
)
