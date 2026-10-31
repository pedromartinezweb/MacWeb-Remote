// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacWebRemote",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacWebRemote", targets: ["MacWebRemote"])],
    dependencies: [.package(url: "https://github.com/brokenhandsio/swift-webauthn.git", revision: "909cf4193cde7d64196553c4245ab647a68aaaca")],
    targets: [
        .target(name: "NativeBridge", path: "NativeBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics")]),
        .target(name: "RemoteAuth", dependencies: [.product(name: "WebAuthn", package: "swift-webauthn")], path: "Auth"),
        .executableTarget(name: "MacWebRemote", dependencies: ["NativeBridge", "RemoteAuth"], path: "Sources", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreGraphics"), .linkedFramework("CoreImage"), .linkedFramework("IOKit"), .linkedFramework("Network"), .linkedFramework("Security")]),
        .testTarget(name: "RemoteAuthTests", dependencies: ["RemoteAuth"], path: "AuthTests")
    ],
    swiftLanguageModes: [.v5]
)
