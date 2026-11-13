// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolMix",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Atualização automática. Versão fixa: mudar de propósito, conferindo as notas do Sparkle.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "VolMix",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VolMix",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOBluetooth"),
                // O Sparkle.framework vai em DeadNoise.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
