//
//  PrivateReportConsistency.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// Keeps the private report lists honest against CloudKit's eventually consistent query index.
///
/// A public-database query is answered from an index that lags behind writes: for a while after a
/// report is deleted the query can still return it, so a refresh used to put a report the developer
/// had just deleted straight back on the sender's screen. Fetching a record **by ID** is not served
/// from that index - it answers `.unknownItem` as soon as the record is gone. So every refresh checks
/// the reports the query returned by ID, and the ones that are gone are dropped and remembered for the
/// session (`tombstones`), so a lagging query cannot bring them back.
///
/// The rules are kept free of CloudKit I/O so they can be tested.
enum PrivateReportConsistency {

    /// `reports` without any report known to be deleted.
    static func pruned(_ reports: [PrivateReport], removing gone: Set<String>) -> [PrivateReport] {

        guard !gone.isEmpty else { return reports }

        return reports.filter { !gone.contains($0.id.recordName) }
    }

    /// The record names an existence check (`records(for:)`) reported as missing. Any other per-record
    /// failure - a network drop, a rate limit - says nothing about the record, so it is kept.
    static func missingNames(in results: [(CKRecord.ID, Result<Void, any Error>)]) -> Set<String> {

        Set(results.compactMap { id, result in

            guard case .failure(let error) = result, CloudKitErrorHandler.isRecordMissing(error) else { return nil }

            return id.recordName
        })
    }
}


/// The check `PrivateReportService.submit` makes on the record CloudKit hands back: every file sent
/// must be on it. If not, the submission is reported as failed instead of "sent" with the file
/// silently missing.
enum PrivateReportSubmissionCheck {

    /// `nil` when `saved` lists exactly the files that were sent; otherwise the name of the first file
    /// that is not there.
    static func missingFile(sent: [String], saved: [PrivateFile]) -> String? {

        guard saved.count < sent.count else { return nil }

        return sent[saved.count]
    }

    /// The first pending file whose temporary copy is gone - it would otherwise upload as nothing.
    static func firstUnavailable(_ files: [PendingFileAttachment],
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> PendingFileAttachment? {

        files.first { !exists($0.url) }
    }
}


extension PrivateReportConsistency {

    /// The query's reports plus the ones this device has just created and the index does not list
    /// yet - the same lag in the other direction, which made a fresh report vanish on the first
    /// refresh. Those are put first (newest first), as `submit` lists them. A query copy always wins.
    ///
    /// - Returns: The list to show, and the pending reports the query still does not return.
    static func merging(query: [PrivateReport], pending: [PrivateReport]) -> (reports: [PrivateReport], stillPending: [PrivateReport]) {

        let listed = Set(query.map(\.id))
        let unlisted = pending.filter { !listed.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }

        return (unlisted + query, unlisted)
    }
}
