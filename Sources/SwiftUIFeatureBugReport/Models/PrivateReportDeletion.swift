//
//  PrivateReportDeletion.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// The rules behind `PrivateReportService.deleteReport(_:)`, the developer deleting one whole private
/// report, free of CloudKit I/O so they can be tested.
enum PrivateReportDeletion {

    /// The follow-ups to delete with the report: every `PrivateReply` whose `report` reference names
    /// it, whoever wrote it. Deduplicated, in the order given.
    ///
    /// They are deleted explicitly rather than left to the `.deleteSelf` cascade, so nothing depends on
    /// the cascade having run.
    static func followUpIDs(_ followUps: [(id: CKRecord.ID, reportName: String)], reportName: String) -> [CKRecord.ID] {

        var seen: Set<CKRecord.ID> = []

        return followUps.compactMap { followUp in

            guard followUp.reportName == reportName, seen.insert(followUp.id).inserted else { return nil }

            return followUp.id
        }
    }

    /// The pending deletion requests that deleting this report fulfils completely, so they can be
    /// removed from the queue: `.reports` requests **from the report's own creator** naming only this
    /// report.
    ///
    /// An `.all` request is never fulfilled here - it also covers the requester's other reports, and
    /// any sent later. A request naming other reports too stays, and `process(_:)` skips the ones
    /// already gone. A request from anyone else did not ask for this report to be deleted.
    static func fulfilledRequests(_ requests: [PrivateDeletionRequest],
                                  reportName: String,
                                  reportCreator: String) -> [PrivateDeletionRequest] {

        guard !reportCreator.isEmpty else { return [] }

        return requests.filter { request in

            request.scope == .reports
                && request.requesterID == reportCreator
                && !request.reportNames.isEmpty
                && request.reportNames.allSatisfy { $0 == reportName }
        }
    }

    /// Whether a directory under `FeedbackFiles` holds a downloaded copy of one of this report's files.
    /// `PrivateReportService.copyOut` names them `<sanitised report name>-<index>`; the index must be
    /// all digits, so a report whose name is a prefix of another's never takes the other's copies.
    static func isCachedFileDirectory(_ directoryName: String, reportName: String) -> Bool {

        let prefix = FileAttachmentName.sanitized(reportName, fallback: "report") + "-"

        guard directoryName.hasPrefix(prefix) else { return false }

        let index = directoryName.dropFirst(prefix.count)

        return !index.isEmpty && index.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether `url` is a local image copy made by `FeedbackImage.copyOut` - a `feedback-asset-` file
    /// directly in the temporary directory - and so safe to remove. Anything else is left alone.
    static func isCachedImageCopy(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {

        guard url.isFileURL, url.lastPathComponent.hasPrefix("feedback-asset-") else { return false }

        return url.deletingLastPathComponent().standardizedFileURL.path == temporaryDirectory.standardizedFileURL.path
    }
}
