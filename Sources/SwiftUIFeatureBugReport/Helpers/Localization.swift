//
//  Localization.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// Never traps, unlike the generated `Bundle.module`.
private final class FeedbackBundleToken {}

extension Bundle {

    /// The package's own resource bundle, which carries `Localizable.xcstrings` (English and Simplified
    /// Chinese). Every user-facing string in the package is looked up here rather than in `Bundle.main`,
    /// so the host app gets the translations without copying any keys into its own catalogue.
    ///
    /// Found the way SwiftPM's generated `Bundle.module` finds it, with one difference that matters: the
    /// generated accessor calls `fatalError` when the bundle is missing, and this falls back to
    /// `Bundle.main` instead - where every key reads as its own English source string. Resolved lazily,
    /// on the first lookup, which only a feedback screen (or a push subscription it saves) makes.
    static let feedbackResources: Bundle = FeedbackResourceBundle.locate() ?? .main
}


enum FeedbackResourceBundle {

    /// `<package>_<target>.bundle`, the name both Xcode and SwiftPM give a package target's resources.
    static let name = "SwiftUIFeatureBugReport_SwiftUIFeatureBugReport"

    static func locate() -> Bundle? {

        let finder = Bundle(for: FeedbackBundleToken.self)

        let directories = [Bundle.main.resourceURL, finder.resourceURL, Bundle.main.bundleURL, finder.bundleURL]

        for directory in directories.compactMap({ $0 }) {

            if let bundle = Bundle(url: directory.appendingPathComponent(name + ".bundle")) { return bundle }
        }

        // The prefix is the package's name as the build saw it, which is not guaranteed to keep this
        // exact case on a case-sensitive file system. Look for the target suffix instead.
        let suffix = "_swiftuifeaturebugreport.bundle"

        for directory in directories.compactMap({ $0 }) {

            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

            if let match = contents.first(where: { $0.lastPathComponent.lowercased().hasSuffix(suffix) }),
               let bundle = Bundle(url: match) {

                return bundle
            }
        }

        return nil
    }
}


/// A user-facing string from the package's catalogue, for APIs that take a `String` (`Button`, `Label`,
/// `navigationTitle`, `alert`, …) rather than a `LocalizedStringKey` with a bundle.
///
/// Interpolations become format arguments exactly as they do for `String(localized:)`, so
/// `loc("Fixed in \(version)")` looks up `"Fixed in %@"`. The compiler's string extraction sees these
/// literals too, because the parameter is a `String.LocalizationValue`.
func loc(_ key: String.LocalizationValue) -> String {

    String(localized: key, bundle: .feedbackResources)
}

/// The same lookup, deferred: for public API typed `LocalizedStringResource`.
func locResource(_ key: String.LocalizationValue) -> LocalizedStringResource {

    LocalizedStringResource(key, bundle: .atURL(Bundle.feedbackResources.bundleURL))
}
