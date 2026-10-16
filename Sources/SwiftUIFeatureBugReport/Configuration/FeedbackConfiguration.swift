//
//  FeedbackConfiguration.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// Everything the package needs from the integrating app.
///
/// Each integrator runs this on their **own** CloudKit container under their own Apple Developer
/// account - the package ships no credentials and the package author receives no data.
public struct FeedbackConfiguration: Sendable {

    /// e.g. `iCloud.com.yourcompany.yourapp`. Must also be listed in the app target's iCloud capability.
    public let containerIdentifier: String

    /// CloudKit user record IDs (`_abc123...`) that should see the developer portal.
    ///
    /// A list rather than a single constant so a team can have more than one developer. When this
    /// list is hard-coded into the app, changing it requires a new build.
    ///
    /// This gates the portal **UI only**. The `dev` security role in the CloudKit Dashboard is what
    /// actually authorises developer writes, so shipping the portal in every build is not a hole.
    public let developerUserRecordIDs: [String]

    /// Number of reports at which a `visible` request auto-hides for everyone. See `ReportService`.
    public let reportThreshold: Int

    /// Whether users may reply on their own requests.
    ///
    /// Turning this off is a real decision, not a cosmetic one: every reply is a message someone
    /// expects an answer to. Developer replies are unaffected - a user can still be answered, they
    /// just cannot start a thread.
    ///
    /// **This is a UI convention, not a security boundary.** CloudKit cannot express "only the request
    /// creator may comment", so a determined user could still write a `Comment` record directly. To
    /// make it enforced, omit the `Comment` record type from your schema entirely - see the README.
    /// When it is `false` the package skips every query for that record type, so leaving it out is
    /// safe.
    public let allowComments: Bool

    /// Whether users may attach screenshots.
    ///
    /// Images are the bulk of a public container's storage, and accepting user-submitted pictures
    /// raises the moderation bar considerably. Text-only is a legitimate choice. Images already
    /// attached before this was turned off still display.
    public let allowImageAttachments: Bool

    /// Whether submissions can be sent privately, to the developer only. See `PrivateFeedbackMode`.
    ///
    /// Defaults to `.disabled` because it needs the `PrivateReport` record type, which a schema
    /// deployed before this option existed will not have. Deploy the schema first, then turn it on.
    public let privateFeedback: PrivateFeedbackMode

    /// Identifies this app when several apps share one container, e.g. `"BeeDay"`.
    ///
    /// When set, new requests, private reports and activity are stamped with it, and the board, the
    /// roadmap, search, Updates and "My private reports" show only this app's records. The developer
    /// portal still shows every app, with a filter. `nil`, the default, writes nothing and shows
    /// everything - the behaviour before this option existed.
    ///
    /// **A display filter, not a security boundary** - see `AppScope`. Use separate containers if the
    /// apps' data must be kept apart.
    public let appID: String?

    /// Whether records with no `appID` - written before scoping was turned on - still show when
    /// `appID` is set. Defaults to `false`: in a shared container nobody can tell which app an
    /// unscoped record came from. Turn it on for the one app that owned the container before the others
    /// joined it, so its existing feedback stays visible.
    public let includeUnscopedRecords: Bool

    /// The scope derived from `appID` and `includeUnscopedRecords`.
    public var appScope: AppScope { AppScope(appID: appID, includesUnscopedRecords: includeUnscopedRecords) }

    public init(containerIdentifier: String,
                developerUserRecordIDs: [String] = [],
                reportThreshold: Int = 3,
                allowComments: Bool = true,
                allowImageAttachments: Bool = true,
                privateFeedback: PrivateFeedbackMode = .disabled,
                appID: String? = nil,
                includeUnscopedRecords: Bool = false) {

        self.containerIdentifier = containerIdentifier
        self.developerUserRecordIDs = developerUserRecordIDs
        self.reportThreshold = reportThreshold
        self.allowComments = allowComments
        self.allowImageAttachments = allowImageAttachments
        self.privateFeedback = privateFeedback
        self.appID = AppScope.normalized(appID)
        self.includeUnscopedRecords = includeUnscopedRecords
    }

}
