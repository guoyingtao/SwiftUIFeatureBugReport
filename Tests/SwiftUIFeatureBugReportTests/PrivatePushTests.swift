//
//  PrivatePushTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

private func configuration(mode: PrivateFeedbackMode = .only,
                           appID: String? = "BeeDay",
                           includeUnscoped: Bool = false,
                           notifications: Bool = true) -> FeedbackConfiguration {

    FeedbackConfiguration(containerIdentifier: "iCloud.com.example.feedback",
                          developerUserRecordIDs: ["_dev"],
                          privateFeedback: mode,
                          appID: appID,
                          includeUnscopedRecords: includeUnscoped,
                          allowFileAttachments: true,
                          privateNotifications: notifications)
}

@Suite("Private feedback push notifications")
struct PrivatePushTests {

    // MARK: Who registers what

    @Test("A sender holds only the report-updated subscription; a developer holds all three")
    func kindsByRole() {

        let config = configuration()

        #expect(PrivatePushKind.kinds(isDeveloper: false, configuration: config) == [.reportUpdated])
        #expect(PrivatePushKind.kinds(isDeveloper: true, configuration: config)
                == [.reportUpdated, .developerNewReport, .developerNewFollowUp])
    }

    @Test("Nothing registers with privateNotifications off or private feedback disabled")
    func kindsDisabled() {

        #expect(PrivatePushKind.kinds(isDeveloper: true, configuration: configuration(notifications: false)).isEmpty)
        #expect(PrivatePushKind.kinds(isDeveloper: true, configuration: configuration(mode: .disabled)).isEmpty)
        #expect(PrivatePushKind.kinds(isDeveloper: false, configuration: configuration(mode: .optional)) == [.reportUpdated])
    }

    @Test("privateNotifications defaults to on, and the apps' existing call compiles unchanged")
    func configurationDefault() {

        let config = FeedbackConfiguration(containerIdentifier: "iCloud.com.echo.feedback",
                                           developerUserRecordIDs: ["_26f4426f35060b6fe13eda0931a8d420"],
                                           privateFeedback: .only,
                                           appID: "BeeReader",
                                           allowFileAttachments: true)

        #expect(config.privateNotifications)
    }

    // MARK: Record types, options, predicates

    @Test("Record types and firing options")
    func options() {

        #expect(PrivatePushKind.reportUpdated.recordType == RecordType.privateReport)
        #expect(PrivatePushKind.developerNewReport.recordType == RecordType.privateReport)
        #expect(PrivatePushKind.developerNewFollowUp.recordType == RecordType.privateReply)

        // The sender made the record, so its creation must not notify them; only updates do.
        #expect(PrivatePushKind.reportUpdated.options == [.firesOnRecordUpdate])
        #expect(PrivatePushKind.developerNewReport.options == [.firesOnRecordCreation])
        #expect(PrivatePushKind.developerNewFollowUp.options == [.firesOnRecordCreation])
    }

    @Test("Predicates are scoped to the sender and the app")
    func predicates() {

        let scope = AppScope(appID: "BeeDay")

        let updated = PrivatePushKind.reportUpdated.predicate(userRecordName: "_me", scope: scope).predicateFormat
        #expect(updated == #"creatorID == "_me" AND appID == "BeeDay""#)

        let newReport = PrivatePushKind.developerNewReport.predicate(userRecordName: "_me", scope: scope).predicateFormat
        #expect(newReport == #"creatorID != "_me" AND appID == "BeeDay""#)

        // TRUEPREDICATE is replaced, never ANDed - CloudKit rejects `TRUEPREDICATE AND ...`.
        let followUp = PrivatePushKind.developerNewFollowUp.predicate(userRecordName: "_me", scope: scope).predicateFormat
        #expect(followUp == #"appID == "BeeDay""#)
    }

    @Test("Unscoped configurations subscribe without an appID clause")
    func unscopedPredicates() {

        #expect(PrivatePushKind.reportUpdated.predicate(userRecordName: "_me", scope: .unscoped).predicateFormat
                == #"creatorID == "_me""#)
        #expect(PrivatePushKind.developerNewFollowUp.predicate(userRecordName: "_me", scope: .unscoped).predicateFormat
                == "TRUEPREDICATE")

        let including = AppScope(appID: "BeeDay", includesUnscopedRecords: true)
        #expect(PrivatePushKind.developerNewReport.predicate(userRecordName: "_me", scope: including).predicateFormat
                == #"creatorID != "_me""#)
    }

    /// CloudKit refuses a subscription whose predicate names a field that is not queryable.
    @Test("Every predicate field is QUERYABLE in both schemas")
    func predicateFieldsAreQueryable() throws {

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        for file in ["Schema.ckdb", "Schema-NoComments.ckdb"] {

            let schema = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)

            for (type, field) in [(RecordType.privateReport, FieldKey.creatorID),
                                  (RecordType.privateReport, FieldKey.appID),
                                  (RecordType.privateReply, FieldKey.appID)] {

                let block = try #require(Self.recordTypeBlock(type, in: schema), "\(type) missing from \(file)")
                let line = block.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(field + " ") }

                #expect(line?.contains("QUERYABLE") == true, "\(type).\(field) must be QUERYABLE in \(file)")
            }
        }
    }

    private static func recordTypeBlock(_ type: String, in schema: String) -> String? {

        guard let start = schema.range(of: "RECORD TYPE \(type) (") else { return nil }

        guard let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex) else { return nil }

        return String(schema[start.upperBound..<end.lowerBound])
    }

    // MARK: Subscription IDs

    @Test("Subscription IDs are deterministic, per user, per app and per kind")
    func subscriptionIDs() {

        let scope = AppScope(appID: "BeeDay")

        #expect(PrivatePushKind.reportUpdated.subscriptionID(userRecordName: "_me", scope: scope) == "private-report-updated-_me-BeeDay")
        #expect(PrivatePushKind.developerNewReport.subscriptionID(userRecordName: "_me", scope: scope) == "developer-private-report-_me-BeeDay")
        #expect(PrivatePushKind.developerNewFollowUp.subscriptionID(userRecordName: "_me", scope: scope) == "developer-private-followup-_me-BeeDay")
        #expect(PrivatePushKind.reportUpdated.subscriptionID(userRecordName: "_me", scope: .unscoped) == "private-report-updated-_me")

        let ids = Set(PrivatePushKind.allCases.map { $0.subscriptionID(userRecordName: "_me", scope: scope) })
        #expect(ids.count == PrivatePushKind.allCases.count)

        // Never colliding with the public activity subscriptions' "activity-" / "developer-new-" stems.
        #expect(ids.allSatisfy { !$0.hasPrefix("activity-") && !$0.hasPrefix("developer-new-") })
    }

    // MARK: Notification content

    @Test("Alerts carry concrete text, not host-app localization keys, and no user content")
    func notificationInfo() throws {

        for kind in PrivatePushKind.allCases {

            let subscription = kind.makeSubscription(userRecordName: "_me", scope: AppScope(appID: "BeeDay"))
            let info = try #require(subscription.notificationInfo)

            #expect(info.title == kind.text.title)
            #expect(info.alertBody == kind.text.body)
            #expect(info.alertBody?.isEmpty == false)
            #expect(info.alertLocalizationKey == nil)
            #expect(info.titleLocalizationKey == nil)
            #expect(info.shouldSendContentAvailable == false)

            let keys = Set(info.desiredKeys ?? [])
            #expect(keys.isDisjoint(with: [FieldKey.title, FieldKey.body, FieldKey.replies]))

            #expect(subscription.subscriptionID == kind.subscriptionID(userRecordName: "_me", scope: AppScope(appID: "BeeDay")))
            #expect(subscription.recordType == kind.recordType)
        }
    }

    // MARK: Re-saving

    private func ledger() -> PrivatePushLedger {

        PrivatePushLedger(defaults: UserDefaults(suiteName: "PrivatePushTests-\(UUID().uuidString)")!)
    }

    @Test("A subscription is saved first time, then skipped while its signature matches")
    func ledgerSkipsMatchingSave() {

        let ledger = ledger()
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(ledger.needsSave(subscriptionID: "s", signature: "a", now: now))

        ledger.recordSaved(subscriptionID: "s", signature: "a", at: now)

        #expect(!ledger.needsSave(subscriptionID: "s", signature: "a", now: now.addingTimeInterval(60)))
        #expect(ledger.needsSave(subscriptionID: "other", signature: "a", now: now))
    }

    @Test("A changed language re-saves the subscription")
    func languageChangeResaves() {

        let ledger = ledger()
        let kind = PrivatePushKind.reportUpdated
        let scope = AppScope(appID: "BeeDay")

        let english = kind.signature(userRecordName: "_me", scope: scope, language: "en-GB")
        let chinese = kind.signature(userRecordName: "_me", scope: scope, language: "zh-Hans")

        #expect(english != chinese)

        let id = kind.subscriptionID(userRecordName: "_me", scope: scope)

        ledger.recordSaved(subscriptionID: id, signature: english)

        #expect(!ledger.needsSave(subscriptionID: id, signature: english))
        #expect(ledger.needsSave(subscriptionID: id, signature: chinese))
    }

    @Test("Signatures also change with the predicate, so a new app scope re-saves")
    func scopeChangeResaves() {

        let kind = PrivatePushKind.developerNewReport

        #expect(kind.signature(userRecordName: "_me", scope: AppScope(appID: "BeeDay"), language: "en-GB")
                != kind.signature(userRecordName: "_me", scope: AppScope(appID: "BeeDay", includesUnscopedRecords: true), language: "en-GB"))
    }

    @Test("A matching save is trusted for a day, and a clock moved backwards is not trusted")
    func ledgerExpiry() {

        let ledger = ledger()
        let now = Date(timeIntervalSince1970: 1_000_000)

        ledger.recordSaved(subscriptionID: "s", signature: "a", at: now)

        #expect(!ledger.needsSave(subscriptionID: "s", signature: "a", now: now.addingTimeInterval(PrivatePushLedger.refreshInterval - 1)))
        #expect(ledger.needsSave(subscriptionID: "s", signature: "a", now: now.addingTimeInterval(PrivatePushLedger.refreshInterval)))
        #expect(ledger.needsSave(subscriptionID: "s", signature: "a", now: now.addingTimeInterval(-1)))
    }

    @Test("Ledger keys use the package's defaults prefix")
    func ledgerKey() {

        #expect(PrivatePushLedger.key(for: "x").hasPrefix("com.swiftuifeaturebugreport."))
    }

    // MARK: Permission

    @Test("Authorised, provisional (and ephemeral) statuses allow alerts; denied and undetermined do not")
    func authorizationStatuses() {

        #expect(PrivateNotificationService.allowsAlerts(.authorized))
        #expect(PrivateNotificationService.allowsAlerts(.provisional))
        #expect(!PrivateNotificationService.allowsAlerts(.denied))
        #expect(!PrivateNotificationService.allowsAlerts(.notDetermined))
    }
}


@Suite("Private push is inert before a feedback screen")
@MainActor struct PrivatePushLazinessTests {

    /// Every entry point checks identity before anything else, so none of this reaches
    /// `UNUserNotificationCenter` (which needs an app bundle) or `CKContainer` (which traps here).
    @Test("Before identity resolves there is nothing to register and nothing is touched")
    func inertBeforeIdentity() async {

        let store = FeedbackStore(configuration: configuration())

        #expect(store.privateNotifications.kinds.isEmpty)

        await store.privateNotifications.refreshIfAuthorized()
        await store.privateNotifications.requestAuthorizationAndRegister()
        await store.askForDeveloperNotificationsIfNeeded()

        #expect(store.container.identityState == .resolving)
    }
}
