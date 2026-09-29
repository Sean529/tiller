// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which builds the Rust static library first
// and passes its directory to the linker.
let package = Package(
    name: "Tiller",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CTillerCore", path: "Sources/CTillerCore"),
        .executableTarget(
            name: "Tiller",
            dependencies: ["CTillerCore"],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
