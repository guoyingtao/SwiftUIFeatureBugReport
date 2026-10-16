//
//  PrivateDeletionRequest.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// What a `PrivateDeletionRequest` asks the developer to delete.
public enum PrivateDeletionScope: String, Sendable, Hashable {

    /// The reports named in `reportNames`.
    case reports

    /// Every private report the requester created, including any sent after the request.
    case all
}


/// A submitter's request that the developer delete their private reports.
///
/// `PrivateReport` grants the creator READ only, so that a submitter cannot rewrite the developer's
/// replies or status - which also means they cannot delete it. They create one of these instead, and the
/// developer processes it from the private reports queue.
///
/// **The requester is CloudKit's own `creatorUserRecordID`, never a field the client wrote.** A field
/// could name anyone, and a developer processing the request would then delete someone else's reports.
public struct PrivateDeletionRequest: Identifiable, Sendable, Hashable {

    public let id: CKRecord.ID
    public let scope: PrivateDeletionScope
    public let reportNames: [String]

    /// The record name of the account that created the request. Empty if CloudKit did not return it,
    /// in which case processing deletes nothing.
    public let requesterID: String
    public let requestedAt: Date

    /// Memberwise, for tests.
    init(id: CKRecord.ID, scope: PrivateDeletionScope, reportNames: [String], requesterID: String, requestedAt: Date = Date()) {

        self.id = id
        self.scope = scope
        self.reportNames = reportNames
        self.requesterID = requesterID
        self.requestedAt = requestedAt
    }

    /// `currentUserRecordID` stands in for CloudKit's `__defaultOwner__` placeholder, which is what a
    /// record created by the signed-in user reports as its creator.
    init?(record: CKRecord, currentUserRecordID: String?) {

        guard record.recordType == RecordType.privateReportDeletionRequest else { return nil }

        self.id = record.recordID
        self.scope = PrivateDeletionScope(rawValue: record[FieldKey.scope] as? String ?? "") ?? .reports
        self.reportNames = record[FieldKey.reportNames] as? [String] ?? []
        self.requesterID = PrivateDeletionPolicy.resolvedCreator(record.creatorUserRecordID?.recordName,
                                                                 currentUserRecordID: currentUserRecordID) ?? ""
        self.requestedAt = record.creationDate ?? .now
    }

    static var desiredKeys: [String] { [FieldKey.scope, FieldKey.reportNames] }
}


/// The rules behind deletion requests, free of CloudKit I/O so they can be tested.
enum PrivateDeletionPolicy {

    /// Maps CloudKit's placeholder for "the signed-in user" to their real record name.
    static func resolvedCreator(_ recordName: String?, currentUserRecordID: String?) -> String? {

        guard let recordName, !recordName.isEmpty else { return nil }

        return recordName == CKCurrentUserDefaultName ? currentUserRecordID : recordName
    }

    /// Whether a report is covered by a pending request **from the report's own creator**.
    ///
    /// The creator match matters for a developer who has also filed a request of their own: their
    /// `.all` request must not mark every other user's report in the developer queue.
    static func isPending(reportName: String, reportCreator: String, in requests: [PrivateDeletionRequest]) -> Bool {

        guard !reportCreator.isEmpty else { return false }

        return requests.contains { request in

            request.requesterID == reportCreator
                && (request.scope == .all || request.reportNames.contains(reportName))
        }
    }

    /// Whether the requester already has a pending request that covers this one, so it need not be filed
    /// again. Only requests whose CloudKit creator is the requester count.
    static func isCovered(scope: PrivateDeletionScope,
                          reportNames: [String],
                          requesterID: String,
                          by existing: [PrivateDeletionRequest]) -> Bool {

        existing.contains { request in

            guard request.requesterID == requesterID else { return false }

            switch (request.scope, scope) {

            case (.all, _): return true
            case (.reports, .all): return false
            case (.reports, .reports): return Set(reportNames).isSubset(of: request.reportNames)
            }
        }
    }

    /// Only private reports may be deleted through a deletion request.
    static func isDeletableTarget(recordType: String) -> Bool { recordType == RecordType.privateReport }

    /// Of the reports a `.reports` request names, the ones the developer may actually delete: those
    /// that exist and were created by the requester. Anything else - a typo, someone else's report
    /// named on purpose - is left alone.
    ///
    /// - Parameter owners: Report record name to its creator's record name, for the reports that
    ///   could be fetched.
    static func deletableReportNames(requested: [String],
                                                 owners: [String: String],
                                                 requesterID: String) -> [String] {

        guard !requesterID.isEmpty else { return [] }

        var seen: Set<String> = []

        return requested.filter { name in

            guard owners[name] == requesterID, !seen.contains(name) else { return false }

            seen.insert(name)

            return true
        }
    }
}
