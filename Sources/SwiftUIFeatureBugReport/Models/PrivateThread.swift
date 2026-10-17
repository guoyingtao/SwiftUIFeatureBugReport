//
//  PrivateThread.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// A submitter's follow-up message on their own private report - one `PrivateReply` record.
///
/// ## Why two stores for one conversation
///
/// `PrivateReply` grants `_icloud` CREATE, `_creator` READ, `dev` READ/WRITE and nothing to `_world`.
/// That suits the **submitter's** messages: they create them, can read them back, can never edit them
/// (no creator WRITE), and the developer reads them through `dev`. It cannot carry the **developer's**
/// messages: a record the developer creates is readable by its creator - the developer - and `dev`,
/// never by the submitter.
///
/// So developer messages stay where they always were, in the report's own `replies` field, which the
/// submitter can read because they created the report, and which is trusted only when a developer last
/// modified the report (`PrivateReportTrust`). `PrivateThread` merges the two into one conversation.
///
/// ## Forgery
///
/// - A submitter cannot make text appear as a developer message: they cannot write the report, and a
///   `PrivateReply` they create is attributed to its CloudKit creator, which is them.
/// - A third party who learns a report's record name can create a `PrivateReply` pointing at it
///   (`_icloud` CREATE). It is shown only if its CloudKit creator is the report's creator or a
///   configured developer; anything else is dropped. CloudKit's creator ID cannot be forged.
public struct PrivateFollowUp: Identifiable, Sendable, Hashable {

    public let id: CKRecord.ID

    /// The report this answers, from the `report` reference.
    public let reportName: String
    public let body: String

    /// CloudKit's authenticated creator - never a client-written field.
    public let creatorID: String
    public let createdAt: Date
    public let appID: String?

    public init(id: CKRecord.ID, reportName: String, body: String, creatorID: String, createdAt: Date, appID: String? = nil) {

        self.id = id
        self.reportName = reportName
        self.body = body
        self.creatorID = creatorID
        self.createdAt = createdAt
        self.appID = AppScope.normalized(appID)
    }

    /// `nil` for another record type, or one with no `report` reference.
    init?(record: CKRecord, currentUserRecordID: String?) {

        guard record.recordType == RecordType.privateReply,
              let reference = record[FieldKey.report] as? CKRecord.Reference else { return nil }

        self.init(id: record.recordID,
                  reportName: reference.recordID.recordName,
                  body: record[FieldKey.body] as? String ?? "",
                  creatorID: PrivateDeletionPolicy.resolvedCreator(record.creatorUserRecordID?.recordName,
                                                                   currentUserRecordID: currentUserRecordID) ?? "",
                  createdAt: record.creationDate ?? .now,
                  appID: record[FieldKey.appID] as? String)
    }

    /// The thread view's keys. The bulk load behind the pending badge asks for `report` only.
    static let desiredKeys = [FieldKey.report, FieldKey.body, FieldKey.appID]
}


/// Who wrote a message in a private conversation.
public enum PrivateMessageAuthor: String, Sendable, Hashable {

    /// The person who sent the report.
    case submitter

    /// A configured developer.
    case developer
}


/// One message in a private conversation, whichever store it came from.
public struct PrivateThreadMessage: Identifiable, Sendable, Hashable {

    public enum Source: Sendable, Hashable {

        /// The report's own title and body - the opening message.
        case report

        /// Entry `index` of the report's trusted `replies`.
        case developerReply(index: Int)

        /// A `PrivateReply` record.
        case followUp(recordName: String)
    }

    public let source: Source
    public let author: PrivateMessageAuthor
    public let body: String
    public let createdAt: Date

    public var id: String {

        switch source {

        case .report: return "report"
        case .developerReply(let index): return "reply-\(index)"
        case .followUp(let name): return "followup-\(name)"
        }
    }
}


/// Merges, filters and reads a private conversation. Pure - no CloudKit I/O.
public enum PrivateThread {

    /// The longest follow-up accepted, the same cap as a developer reply.
    public static let maximumMessageLength = PrivateReply.maximumMessageLength

    /// Who a follow-up is attributed to, or `nil` if it must not be shown: not on this report, or
    /// created by someone who is neither the report's creator nor a developer.
    static func author(of followUp: PrivateFollowUp,
                       on report: PrivateReport,
                       developerUserRecordIDs: [String]) -> PrivateMessageAuthor? {

        guard followUp.reportName == report.id.recordName, !followUp.creatorID.isEmpty else { return nil }

        if followUp.creatorID == report.creatorID { return .submitter }
        if developerUserRecordIDs.contains(followUp.creatorID) { return .developer }

        return nil
    }

    /// The conversation after the opening message, oldest first: the report's trusted developer
    /// `replies` and the follow-ups that pass `author(of:on:developerUserRecordIDs:)`.
    ///
    /// Ties keep developer replies before follow-ups, each in its own order, so the result is stable.
    /// Developer replies are timed by the developer's device clock and follow-ups by CloudKit's, so a
    /// badly wrong device clock can misplace a reply.
    public static func messages(report: PrivateReport,
                                followUps: [PrivateFollowUp],
                                developerUserRecordIDs: [String]) -> [PrivateThreadMessage] {

        var merged: [PrivateThreadMessage] = report.replies.enumerated().map { index, reply in

            PrivateThreadMessage(source: .developerReply(index: index), author: .developer, body: reply.message, createdAt: reply.createdAt)
        }

        var seen = Set<String>()

        for followUp in followUps {

            guard seen.insert(followUp.id.recordName).inserted,
                  let author = author(of: followUp, on: report, developerUserRecordIDs: developerUserRecordIDs) else { continue }

            merged.append(PrivateThreadMessage(source: .followUp(recordName: followUp.id.recordName),
                                               author: author,
                                               body: followUp.body,
                                               createdAt: followUp.createdAt))
        }

        return merged.enumerated()
            .sorted { lhs, rhs in lhs.element.createdAt == rhs.element.createdAt ? lhs.offset < rhs.offset : lhs.element.createdAt < rhs.element.createdAt }
            .map(\.element)
    }

    /// The whole conversation for display: the report itself, then `messages`.
    public static func thread(report: PrivateReport,
                              followUps: [PrivateFollowUp],
                              developerUserRecordIDs: [String]) -> [PrivateThreadMessage] {

        [PrivateThreadMessage(source: .report, author: .submitter, body: report.body, createdAt: report.createdAt)]
            + messages(report: report, followUps: followUps, developerUserRecordIDs: developerUserRecordIDs)
    }

    /// Who spoke last. The report itself counts as the submitter's opening message.
    public static func latestAuthor(report: PrivateReport,
                                    followUps: [PrivateFollowUp],
                                    developerUserRecordIDs: [String]) -> PrivateMessageAuthor {

        messages(report: report, followUps: followUps, developerUserRecordIDs: developerUserRecordIDs).last?.author ?? .submitter
    }

    /// Whether the submitter may still send a follow-up. Closed means `.complete` - `RequestStatus` has
    /// no separate closed or declined state - and only the report's own creator may write.
    public static func acceptsFollowUp(report: PrivateReport, currentUserRecordID: String?) -> Bool {

        guard let me = currentUserRecordID, !me.isEmpty, report.creatorID == me else { return false }

        return report.status != .complete
    }
}
