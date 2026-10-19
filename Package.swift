// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftUIFeatureBugReport",
    // The source language of every string in this package. The package ships its own translations in
    // `Resources/Localizable.xcstrings` (Simplified Chinese), and every lookup names the package's
    // bundle, so the host app needs no keys of its own. See README > Localisation.
    defaultLocalization: "en-GB",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftUIFeatureBugReport",
            targets: ["SwiftUIFeatureBugReport"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftUIFeatureBugReport",
            resources: [
                // Folded into the host app's privacy report by Xcode. See README > Privacy.
                .copy("PrivacyInfo.xcprivacy"),
                // Compiled to `<language>.lproj/Localizable.strings` and `.stringsdict` by Xcode and SwiftPM.
                .process("Resources/Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "SwiftUIFeatureBugReportTests",
            dependencies: ["SwiftUIFeatureBugReport"]
        ),
    ]
)
