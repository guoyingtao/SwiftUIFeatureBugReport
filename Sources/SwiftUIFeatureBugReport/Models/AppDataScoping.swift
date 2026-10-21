//
//  AppDataScoping.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// One of the user's records, reduced to what deciding its app needs.
struct AppScopedRecord: Sendable, Hashable {

    /// The record's CloudKit record name.
    let name: String

    /// The record's own `appID` field. Only `Request`, `PrivateReport` and `Activity` have one.
    let ownAppID: String?

    /// The record name of the `Request` it hangs off (`Vote`, `Comment`, `Report`, `Follow`, ...), if any.
    let parentRequestName: String?

    init(name: String, ownAppID: String? = nil, parentRequestName: String? = nil) {

        self.name = name
        self.ownAppID = AppScope.normalized(ownAppID)
        self.parentRequestName = parentRequestName
    }
}


/// The rules that make "My data" counts and "Delete my data" per-app, free of CloudKit I/O so they can be
/// tested.
///
/// The rule is the same one the board uses (`AppScope.includes(_:)`): with `appID` set, a record counts
/// if its app matches, and a record with no app only if `includesUnscopedRecords` is on. With `appID`
/// `nil` everything counts - the account-wide behaviour from before app scoping.
///
/// A record's app is its own `appID` if it has one, otherwise its parent request's. A child whose parent
/// is gone or carries no `appID` is unscoped.
enum AppDataScoping {

    /// Whether the record set needs a parent lookup at all.
    static func needsParentLookup(_ scope: AppScope) -> Bool { scope.appID != nil }

    /// Parent request names that must be fetched to decide `records`: those with no app of their own.
    static func parentNamesToResolve(_ records: [AppScopedRecord]) -> Set<String> {

        Set(records.filter { $0.ownAppID == nil }.compactMap(\.parentRequestName))
    }

    /// The app a record belongs to. `parentAppIDs` maps a request's record name to its `appID`; a
    /// request that is missing or has no `appID` is simply absent.
    static func effectiveAppID(of record: AppScopedRecord, parentAppIDs: [String: String]) -> String? {

        if let own = record.ownAppID { return own }

        guard let parent = record.parentRequestName else { return nil }

        return AppScope.normalized(parentAppIDs[parent])
    }

    /// The records in `scope`, in their original order.
    static func filter(_ records: [AppScopedRecord], parentAppIDs: [String: String], scope: AppScope) -> [AppScopedRecord] {

        guard scope.appID != nil else { return records }

        return records.filter { scope.includes(effectiveAppID(of: $0, parentAppIDs: parentAppIDs)) }
    }

    /// Whether a pending deletion request from `requesterID` covers this app's private reports.
    ///
    /// Account-wide, any request counts. Per-app, an `.all` request counts, and a `.reports` request
    /// only if it names one of this app's reports - a request filed from another app is that app's.
    static func hasPendingDeletion(_ requests: [PrivateDeletionRequest],
                                   requesterID: String,
                                   scopedReportNames: Set<String>,
                                   scope: AppScope) -> Bool {

        requests.contains { request in

            guard request.requesterID == requesterID else { return false }

            guard scope.appID != nil else { return true }

            return request.scope == .all || !scopedReportNames.isDisjoint(with: request.reportNames)
        }
    }

    /// The deletion request a submitter files from "Delete my data": every report account-wide, or the
    /// named reports of this app only. `nil` when there is nothing to ask for.
    static func deletionRequest(scope: AppScope, scopedReportNames: [String]) -> (scope: PrivateDeletionScope, reportNames: [String])? {

        guard !scopedReportNames.isEmpty else { return nil }

        guard scope.appID != nil else { return (.all, []) }

        return (.reports, scopedReportNames.sorted())
    }

    /// Which of the user's deletion requests a developer may remove after deleting `deletedReportNames`.
    ///
    /// Account-wide every request is fulfilled. Per-app only a `.reports` request whose every named report
    /// was just deleted is: an `.all` request, or one naming another app's reports, still has work left
    /// in another app and stays in that app's queue.
    static func fulfilledDeletionRequests(_ requests: [PrivateDeletionRequest],
                                          deletedReportNames: Set<String>,
                                          scope: AppScope) -> [PrivateDeletionRequest] {

        guard scope.appID != nil else { return requests }

        return requests.filter { $0.scope == .reports && !$0.reportNames.isEmpty && Set($0.reportNames).isSubset(of: deletedReportNames) }
    }
}
