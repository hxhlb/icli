// swift-tools-version:5.9
import PackageDescription

/// A long-running IcliKit host, run on a device by scripts/host-soak.py: the
/// way a daemon such as vphoned uses the library, which the one-shot CLI and
/// its acceptance suite never exercise.
let package = Package(
    name: "IcliHostSoak",
    platforms: [.iOS(.v15)],
    products: [.executable(name: "IcliHostSoak", targets: ["IcliHostSoak"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "IcliHostSoak",
            dependencies: [.product(name: "IcliKit", package: "icli")],
        ),
    ],
)
