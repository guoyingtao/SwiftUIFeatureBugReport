//
//  PrivateNotificationService.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation
import Observation
import os
import UserNotifications

/// Push notifications for private feedback, both ways. See `PrivatePushKind` for what is sent to whom.
///
/// Nothing here runs until a feedback screen is on screen: the initialiser stores its arguments and
/// nothing else, and every entry point returns early unless identity has resolved - which only happens
/// after `FeedbackContainer.prepare()` has passed its entitlement check.
///
/// Every failure is logged and swallowed. A missing Push Notifications capability, a refused
/// permission, no network or a schema without these record types all end the same way: no pushes,
/// and nothing else changes.
@Observable @MainActor public final class PrivateNotificationService {

    private let container: FeedbackContainer

    @ObservationIgnored private let ledger: PrivatePushLedger

    /// One save pass at a time; a second caller while one runs has nothing to add.
    @ObservationIgnored private var isSaving = false

    private static let log = Logger(subsystem: "com.swiftuifeaturebugreport", category: "push")

    init(container: FeedbackContainer, ledger: PrivatePushLedger = PrivatePushLedger()) {

        self.container = container
        self.ledger = ledger
    }

    /// The subscriptions this device should hold right now. Empty while signed out, when
    /// `privateNotifications` is off, or when private feedback is disabled.
    public var kinds: [PrivatePushKind] {

        guard container.identityState == .ready else { return [] }

        return PrivatePushKind.kinds(isDeveloper: container.isDeveloper, configuration: container.configuration)
    }

    /// When a feedback screen opens. **Never prompts**: only if notifications are already allowed does
    /// it register with APNs (needed every launch) and make sure the subscriptions exist.
    public func refreshIfAuthorized() async {

        guard !kinds.isEmpty, await Self.isAuthorized() else { return }

        container.registerForRemoteNotifications()

        await saveSubscriptions()
    }

    /// After the user has sent private feedback or a follow-up, or a developer has opened the portal.
    ///
    /// The system prompt appears only while permission is `.notDetermined` - at most once per install -
    /// and nothing waits on it: callers fire this and carry on (see `FeedbackStore.didSendPrivateFeedback`).
    public func requestAuthorizationAndRegister() async {

        guard !kinds.isEmpty else { return }

        guard await Self.requestAuthorization() else { return }

        container.registerForRemoteNotifications()

        await saveSubscriptions()
    }

    // MARK: - Subscriptions

    private func saveSubscriptions() async {

        guard !isSaving, let me = container.currentUserRecordID else { return }

        isSaving = true
        defer { isSaving = false }

        let scope = container.configuration.appScope
        let language = Self.currentLanguage

        for kind in kinds {

            let id = kind.subscriptionID(userRecordName: me, scope: scope)
            let signature = kind.signature(userRecordName: me, scope: scope, language: language)

            guard ledger.needsSave(subscriptionID: id, signature: signature) else { continue }

            if await save(kind.makeSubscription(userRecordName: me, scope: scope)) {

                ledger.recordSaved(subscriptionID: id, signature: signature)
            }
        }
    }

    /// Saving over an existing ID replaces it. Should the server refuse that instead, the old one is
    /// deleted and the save tried once more - which is also how a changed language reaches the server.
    private func save(_ subscription: CKQuerySubscription) async -> Bool {

        let database = container.database

        do {

            _ = try await database.save(subscription)

            return true
        }
        catch let error as CKError where error.code == .serverRejectedRequest {

            do {

                _ = try? await database.deleteSubscription(withID: subscription.subscriptionID)
                _ = try await database.save(subscription)

                return true
            }
            catch {

                Self.log.error("Could not replace push subscription \(subscription.subscriptionID, privacy: .public): \(error.localizedDescription, privacy: .public)")

                return false
            }
        }
        catch {

            Self.log.error("Could not save push subscription \(subscription.subscriptionID, privacy: .public): \(error.localizedDescription, privacy: .public)")

            return false
        }
    }

    /// The language the package's own strings resolve to, which is the language the push text was
    /// written in.
    static var currentLanguage: String { Bundle.feedbackResources.preferredLocalizations.first ?? "en" }

    // MARK: - Permission

    static func isAuthorized() async -> Bool {

        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus

        return Self.allowsAlerts(status)
    }

    /// Prompts only when undetermined; otherwise answers from the current setting.
    static func requestAuthorization() async -> Bool {

        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus

        guard status == .notDetermined else { return allowsAlerts(status) }

        do {

            return try await centre.requestAuthorization(options: [.alert, .sound, .badge])
        }
        catch {

            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")

            return false
        }
    }

    nonisolated static func allowsAlerts(_ status: UNAuthorizationStatus) -> Bool {

        #if os(iOS)
        if status == .ephemeral { return true }
        #endif

        return status == .authorized || status == .provisional
    }
}
