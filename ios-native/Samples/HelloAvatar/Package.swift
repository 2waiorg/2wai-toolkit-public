// swift-tools-version:5.9
import PackageDescription

// Standalone executable sample for TwaiAvatarKit.
// Points at the sibling TwaiAvatarKit package via a local path dep so
// you can iterate on both at once without publishing. For a real app,
// swap the local path for a git-URL dep.

let package = Package(
    name: "HelloAvatar",
    platforms: [.iOS(.v15)],
    products: [
        .executable(name: "HelloAvatar", targets: ["HelloAvatar"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "HelloAvatar",
            dependencies: [
                .product(name: "TwaiPlayer", package: "ios-native"),
            ],
            path: "HelloAvatar"
        ),
    ]
)
