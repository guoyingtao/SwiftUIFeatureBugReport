//
//  FeedbackContainer.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The outcome of `FeedbackContainer.prepare()`.
public enum FeedbackAvailability: Sendable, Equatable {

    case available
    case unavailable(FeedbackUnavailableReason)
}


/// Where the identity resolution has got to.
///
/// Views must not render row-level state until this reaches `.ready`. Rendering earlier means every
/// row reads "not mine, not voted" and then visibly flips a moment later.
public enum IdentityState: Sendable, Equatable {

    case resolving
    case ready
    case noAccount
    case failed(String)
}

/// Owns the `CKContainer` and the signed-in identity. Every other service takes one of these.
@Observable @MainActor public final class FeedbackContainer {

    public let configuration: FeedbackConfiguration

    public private(set) var identityState: IdentityState = .resolving
    public private(set) var currentUserRecordID: String?
    public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine

    /// Gates the portal **UI**. The `dev` security role is what actually enforces developer writes,
    /// so a user who somehow flipped this would still be refused by the server.
    public var isDeveloper: Bool {

        guard let currentUserRecordID else { return false }

        return configuration.developerUserRecordIDs.contains(currentUserRecordID)
    }

    /// Writing to the public database needs a signed-in iCloud account. Reading does not, so this
    /// disables voting and submitting rather than failing the whole screen.
    public var canWrite: Bool { identityState == .ready }

    /// The CloudKit container. **Created on first use, never in `init`.**
    ///
    /// `CKContainer(identifier:)` traps - an uncatchable crash, not an error - when the app is not
    /// entitled to the container. Creating it in `init` meant merely *constructing* a board (which
    /// SwiftUI does for every `NavigationLink(destination:)` on a settings screen) could take the host
    /// app down. It is now created by `prepare()`, which first checks the signed entitlements. The
    /// package's views call `prepare()` before rendering anything that touches CloudKit, and show an
    /// error state instead when it reports `.unavailable`.
    ///
    /// Reading this before `prepare()` has succeeded still creates the container directly, which traps
    /// exactly as before if the entitlement really is missing. Check `prepare()` first.
    public var container: CKContainer {

        if let containerStorage { return containerStorage }

        prepare()

        if let containerStorage { return containerStorage }

        // Only reachable by host code that ignored an `.unavailable` result from `prepare()`.
        let created = CKContainer(identifier: configuration.containerIdentifier)

        containerStorage = created

        return created
    }

    public var database: CKDatabase { container.publicCloudDatabase }

    @ObservationIgnored private var containerStorage: CKContainer?

    /// The cached outcome of `prepare()`. Ignored by observation so `prepare()` can run while a view
    /// body is being evaluated without invalidating it.
    @ObservationIgnored private var availability: FeedbackAvailability?

    /// `nonisolated(unsafe)` so `deinit` can unregister. Written once in `prepare()` (main actor) and
    /// read once in `deinit`, never concurrently.
    @ObservationIgnored private nonisolated(unsafe) var accountObserver: (any NSObjectProtocol)?

    /// Called after `.CKAccountChanged` so dependent services can drop their derived state.
    var onIdentityChange: (@MainActor () -> Void)?

    /// Cheap and side-effect free: stores the configuration and nothing else. No `CKContainer`, no
    /// notification observer, no I/O - all of that waits for `prepare()`.
    public init(configuration: FeedbackConfiguration) {

        self.configuration = configuration
    }

    deinit {

        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    // MARK: - Preparation

    /// Whether CloudKit can be used, creating the container and the account observer if it can.
    ///
    /// Idempotent and synchronous; the first call reads the app's signed entitlements once per process
    /// (`CloudKitEntitlementFacts.current`). Only a *definite* problem - an invalid identifier, or
    /// entitlements that were read and lack CloudKit or this container - returns `.unavailable`. When
    /// the entitlements cannot be read, the container is created as before.
    @discardableResult public func prepare() -> FeedbackAvailability {

        if let availability { return availability }

        let identifier = configuration.containerIdentifier
        let problem = CloudKitEntitlementFacts.identifierProblem(identifier)
            ?? CloudKitEntitlementFacts.current?.problem(forContainer: identifier)

        let result: FeedbackAvailability

        if let problem {

            result = .unavailable(problem)
        }
        else {

            containerStorage = CKContainer(identifier: identifier)
            observeAccountChanges()
            result = .available
        }

        availability = result

        return result
    }

    /// The reason the feedback screens cannot work, or `nil` once `prepare()` has succeeded.
    public var unavailableReason: FeedbackUnavailableReason? {

        if case .unavailable(let reason) = prepare() { return reason }

        return nil
    }

    // MARK: - Identity

    public func resolveIdentity() async {

        if let unavailableReason {

            currentUserRecordID = nil
            identityState = .failed(unavailableReason.localizedDescription)

            return
        }

        identityState = .resolving

        do {

            accountStatus = try await container.accountStatus()

            guard accountStatus == .available else {

                currentUserRecordID = nil
                identityState = .noAccount

                return
            }

            let recordID = try await container.userRecordID()

            currentUserRecordID = recordID.recordName
            identityState = .ready
        }
        catch {

            currentUserRecordID = nil

            let feedbackError = CloudKitErrorHandler.classify(error)

            // A missing account is a state, not a failure - the board still reads.
            identityState = feedbackError == .notSignedIn
                ? .noAccount
                : .failed(feedbackError.localizedDescription)
        }
    }

    /// This matters more for a first sign-in, or re-auth after a password change, than for someone
    /// deliberately switching Apple Accounts - but all three land here.
    private func observeAccountChanges() {

        guard accountObserver == nil else { return }

        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged,
                                                                 object: nil,
                                                                 queue: .main) { [weak self] _ in

            // The notification arrives on the main queue, but nothing about `Notification` is Sendable,
            // so hop explicitly rather than capturing it.
            Task { @MainActor [weak self] in

                guard let self else { return }

                await self.resolveIdentity()

                self.onIdentityChange?()
            }
        }
    }

    /// Whether a record's creator is this user.
    ///
    /// CloudKit does **not** stamp your own actual user record ID onto records you created - it
    /// returns `CKCurrentUserDefaultName` ("__defaultOwner__") instead. Comparing straight against
    /// `currentUserRecordID` therefore never matches your own records, which silently made every
    /// "is this mine?" check say no: your votes read as unvoted, your follows as unfollowed, and
    /// content you reported came back after a reload.
    public func isCurrentUser(_ recordID: CKRecord.ID?) -> Bool {

        guard let recordID else { return false }

        if recordID.recordName == CKCurrentUserDefaultName { return true }

        return recordID.recordName == currentUserRecordID
    }

    // MARK: - Push registration

    /// Platform split only - the rest of the subscription work is identical (§8.4).
    public func registerForRemoteNotifications() {

        #if os(iOS) || targetEnvironment(macCatalyst)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }
}


extension FeedbackError: Equatable {

    public static func == (lhs: FeedbackError, rhs: FeedbackError) -> Bool {

        lhs.localizedDescription == rhs.localizedDescription
    }
}
