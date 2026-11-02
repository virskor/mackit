// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mackit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mackit", targets: ["Mackit"])
    ],
    dependencies: [
        // Sparkle 2: in-app automatic updates (appcast + EdDSA signature +
        // code-signing verification).
        // Distributed as a binary XCFramework; build-app.sh then copies the
        // framework into .app/Contents/Frameworks and signs it layer by
        // layer from the inside out (the framework embeds Updater.app and
        // two XPC services, which must be signed themselves; the vendor's
        // own signatures cannot pass notarization).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // The privileged helper's shared vocabulary: the XPC protocol, the
        // install paths and the request validation both sides enforce. A
        // library rather than duplicated files because SwiftPM forbids one
        // source file belonging to two targets, and the validation is the
        // helper's trust boundary — a second hand-maintained copy is a
        // second chance to get it wrong.
        .target(
            name: "MackitHelperKit",
            path: "Sources/MackitHelperKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        // The privileged helper daemon: a root process launchd starts from
        // /Library/LaunchDaemons, reached over an XPC Mach service, whose
        // entire command set is launchctl's system-domain service
        // enable/disable. It links neither Sparkle nor SwiftUI — a root
        // process carries the smallest possible dependency set — and
        // build-app.sh embeds it in Contents/Library/PrivilegedHelperTools.
        .executableTarget(
            name: "MackitHelper",
            dependencies: [
                "MackitHelperKit"
            ],
            path: "Sources/MackitHelper",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        // Only one executable target for the app itself: the tray agent and
        // the main program are the same binary, installed in two bundles
        // with the role distinguished by bundle ID (see MackitApp.isAgent).
        //
        // Why not split it into "a library + two executable targets":
        // SwiftPM forbids one source file belonging to multiple targets,
        // so splitting out a library would require marking every
        // cross-module type in the library as public—dozens of members of
        // the ViewModel, more than twenty views (those with stored
        // properties would also need hand-written public init), models and
        // utilities, over a hundred changes, and the encapsulation posture
        // of the whole codebase changes with it. The runtime divergence of
        // one binary across two bundles costs nothing, and the test target
        // still depends on this target as before.
        //
        // The cost: the agent bundle must carry a copy of Sparkle.framework
        // (the binary links against it; without the framework the agent
        // cannot start; 2.9MB, and the agent never launches the updater).
        .executableTarget(
            name: "Mackit",
            dependencies: [
                "Sparkle",
                "MackitHelperKit"
            ],
            path: "Sources/Mackit",
            // Brand mark SVGs (Resources/BrandLogos) are copied as-is by
            // .process; only the folder's README is documentation, not an
            // app asset, and stays out of the bundle.
            exclude: [
                "Resources/BrandLogos/README.md"
            ],
            resources: [
                // String Catalog: source language zh-Hans, plus en,
                // zh-Hant, ko and ja. At build time it is compiled into
                // *.lproj
                // inside Mackit_Mackit.bundle, which build-app.sh then
                // copies into the Resources of both .apps—the main window
                // and the tray panel both look up the same copy of the
                // strings.
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MackitTests",
            dependencies: ["Mackit", "MackitHelperKit"],
            path: "Tests/MackitTests"
        )
    ]
)
