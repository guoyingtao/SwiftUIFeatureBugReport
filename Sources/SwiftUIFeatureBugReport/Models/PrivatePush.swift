//
//  PrivatePush.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// The three push notifications that private feedback sends, and everything about them that can be
/// decided without a network: who registers which, the predicates, the subscription IDs and the text.
///
/// All of them are `CKQuerySubscription`s on the **public** database - the only subscription type it
/// supports. CloudKit evaluates the predicate server-side and only notifies a subscriber who can read
/// the matching record, so the schema's grants (`_creator` READ, `dev` READ) are what keep a report's
/// pushes going to its own sender and to developers, nobody else.
public enum PrivatePushKind: String, CaseIterable, Sendable, Hashable {

    /// To the sender, when a developer changes their report: a reply (appended to `replies`), a status
    /// change, or an attachment removed. Only developers can write a `PrivateReport` - `_creator` has
    /// READ only - so every update the subscription sees is the developer's.
    case reportUpdated

    /// To a developer, when someone else sends a new private report from this app.
    case developerNewReport

    /// To a developer, when a sender adds a follow-up (`PrivateReply`) to a report from this app.
    case developerNewFollowUp

    public var isDeveloperOnly: Bool { self != .reportUpdated }

    var recordType: CKRecord.RecordType {

        switch self {

        case .reportUpdated, .developerNewReport: return RecordType.privateReport
        case .developerNewFollowUp: return RecordType.privateReply
        }
    }

    /// A sender cannot write their report, so "updated" means "the developer did something". Creation
    /// is excluded: the sender made it. The developer's two only care about new records.
    var options: CKQuerySubscription.Options {

        switch self {

        case .reportUpdated: return [.firesOnRecordUpdate]
        case .developerNewReport, .developerNewFollowUp: return [.firesOnRecordCreation]
        }
    }

    /// The kinds a device should hold. A developer is a sender too, so gets all three.
    public static func kinds(isDeveloper: Bool, configuration: FeedbackConfiguration) -> [PrivatePushKind] {

        guard configuration.privateNotifications, configuration.privateFeedback.offersPrivateReports else { return [] }

        return allCases.filter { isDeveloper || !$0.isDeveloperOnly }
    }

    /// Deterministic, so saving again replaces rather than duplicates. Per user (a shared device can
    /// switch iCloud accounts) and per app, the same as the public activity subscriptions.
    public func subscriptionID(userRecordName me: String, scope: AppScope) -> String {

        let stem: String

        switch self {

        case .reportUpdated: stem = "private-report-updated"
        case .developerNewReport: stem = "developer-private-report"
        case .developerNewFollowUp: stem = "developer-private-followup"
        }

        return "\(stem)-\(me)\(scope.subscriptionSuffix())"
    }

    /// Every field used is `QUERYABLE` in `Schema.ckdb` - CloudKit refuses to save a subscription whose
    /// predicate names a field that is not.
    ///
    /// - `reportUpdated`: `creatorID == me` (+ `appID`). `creatorID` is written by the sender at
    ///   creation; a forged one gains nothing, because the push only goes to someone who can read the
    ///   record, which is its real creator.
    /// - `developerNewReport`: `creatorID != me` (+ `appID`), so the developer's own test reports stay
    ///   quiet - the same rule as the public new-request push.
    /// - `developerNewFollowUp`: `appID` only. `PrivateReply` carries the report's `appID` and no
    ///   `creatorID`; developers reply on the report itself, so these are always from senders.
    public func predicate(userRecordName me: String, scope: AppScope) -> NSPredicate {

        switch self {

        case .reportUpdated:
            return scope.predicate(NSPredicate(format: "%K == %@", FieldKey.creatorID, me))

        case .developerNewReport:
            return scope.predicate(NSPredicate(format: "%K != %@", FieldKey.creatorID, me))

        case .developerNewFollowUp:
            return scope.predicate(NSPredicate(value: true))
        }
    }

    /// The notification's title and body, in the language the package resolves to **now**.
    ///
    /// Concrete text rather than `alertLocalizationKey`: CloudKit's localization keys resolve against
    /// the host app's `Bundle.main`, which does not have the package's catalogue. The subscription is
    /// saved on the recipient's own device, so its language is the recipient's - and a language change
    /// shows up as a different `PrivatePushLedger.signature`, which saves it again.
    ///
    /// Deliberately generic: nothing anyone typed goes into a push.
    public var text: (title: String, body: String) {

        switch self {

        case .reportUpdated:
            return (loc("Feedback update"), loc("The developer replied to or updated your feedback."))

        case .developerNewReport:
            return (loc("New private feedback"), loc("A user sent new private feedback."))

        case .developerNewFollowUp:
            return (loc("New reply on private feedback"), loc("A user replied on their private feedback."))
        }
    }

    /// Only `recordName`s and the kind, so a tap can be routed by the host app if it wants to. Alert
    /// only - no `content-available`, so nothing is woken in the background.
    var desiredKeys: [String] {

        switch self {

        case .reportUpdated, .developerNewReport: return [FieldKey.appID]
        case .developerNewFollowUp: return [FieldKey.report, FieldKey.appID]
        }
    }

    func makeSubscription(userRecordName me: String, scope: AppScope) -> CKQuerySubscription {

        let subscription = CKQuerySubscription(recordType: recordType,
                                               predicate: predicate(userRecordName: me, scope: scope),
                                               subscriptionID: subscriptionID(userRecordName: me, scope: scope),
                                               options: options)

        let info = CKSubscription.NotificationInfo()
        let text = text

        info.title = text.title
        info.alertBody = text.body
        info.soundName = "default"
        info.shouldSendContentAvailable = false
        info.desiredKeys = desiredKeys

        subscription.notificationInfo = info

        return subscription
    }

    /// What a saved subscription is pinned to. Changes when the language, the wording, the predicate
    /// or the options change - each of which means the server copy is stale.
    func signature(userRecordName me: String, scope: AppScope, language: String) -> String {

        let text = text

        return [language,
                text.title,
                text.body,
                recordType,
                predicate(userRecordName: me, scope: scope).predicateFormat,
                String(options.rawValue)].joined(separator: "\u{1F}")
    }
}


/// When each private subscription was last saved, and as what, kept in `UserDefaults` under
/// `com.swiftuifeaturebugreport.pushSubscription.<subscription ID>`.
///
/// A save is a network round trip, so it is skipped when the stored signature still matches and the
/// last save is recent. It is not skipped forever: subscriptions are server state that can disappear
/// (a reset Development environment, a deleted subscription), and the ledger cannot see that.
struct PrivatePushLedger {

    static let keyPrefix = "com.swiftuifeaturebugreport.pushSubscription."

    /// How long a matching save is trusted before it is made again anyway.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(for subscriptionID: String) -> String { keyPrefix + subscriptionID }

    func needsSave(subscriptionID: String, signature: String, now: Date = .now) -> Bool {

        guard let entry = defaults.dictionary(forKey: Self.key(for: subscriptionID)),
              let saved = entry["signature"] as? String,
              let savedAt = entry["savedAt"] as? Date else { return true }

        guard saved == signature else { return true }

        let age = now.timeIntervalSince(savedAt)

        // A clock moved backwards reads as stale too, rather than as trusted for ever.
        return age < 0 || age >= Self.refreshInterval
    }

    func recordSaved(subscriptionID: String, signature: String, at date: Date = .now) {

        defaults.set(["signature": signature, "savedAt": date], forKey: Self.key(for: subscriptionID))
    }

    func forget(subscriptionID: String) {

        defaults.removeObject(forKey: Self.key(for: subscriptionID))
    }
}
