//
//  PrivateThreadTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

private let developers = ["_dev"]

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func report(_ name: String = "pr1",
                    status: RequestStatus = .open,
                    creator: String = "_alice",
                    replies: [(String, Double)] = [],
                    createdAt: Double = 0) -> PrivateReport {

    PrivateReport(id: CKRecord.ID(recordName: name),
                  body: "Opening",
                  status: status,
                  creatorID: creator,
                  replies: replies.map { PrivateReply(message: $0.0, createdAt: date($0.1)) },
                  createdAt: date(createdAt))
}

private func followUp(_ name: String, on reportName: String = "pr1", by creator: String = "_alice", at seconds: Double, body: String? = nil) -> PrivateFollowUp {

    PrivateFollowUp(id: CKRecord.ID(recordName: name), reportName: reportName, body: body ?? name, creatorID: creator, createdAt: date(seconds))
}


@Suite("Private conversation thread")
struct PrivateThreadTests {

    @Test("Developer replies and follow-ups merge into one chronological thread")
    func mergeOrder() {

        let thread = PrivateThread.messages(report: report(replies: [("dev1", 10), ("dev2", 30)]),
                                            followUps: [followUp("user2", at: 40), followUp("user1", at: 20)],
                                            developerUserRecordIDs: developers)

        #expect(thread.map(\.body) == ["dev1", "user1", "dev2", "user2"])
        #expect(thread.map(\.author) == [.developer, .submitter, .developer, .submitter])
    }

    @Test("The full thread opens with the report itself")
    func opening() {

        let thread = PrivateThread.thread(report: report(), followUps: [followUp("u", at: 5)], developerUserRecordIDs: developers)

        #expect(thread.first?.source == .report)
        #expect(thread.first?.author == .submitter)
        #expect(thread.first?.body == "Opening")
        #expect(thread.count == 2)
    }

    @Test("Equal timestamps keep a stable order: developer replies first, then follow-ups as given")
    func ties() {

        let thread = PrivateThread.messages(report: report(replies: [("dev", 10)]),
                                            followUps: [followUp("a", at: 10), followUp("b", at: 10)],
                                            developerUserRecordIDs: developers)

        #expect(thread.map(\.body) == ["dev", "a", "b"])
    }

    @Test("A follow-up from a third party is never shown")
    func thirdPartyDropped() {

        let thread = PrivateThread.messages(report: report(),
                                            followUps: [followUp("mallory", by: "_mallory", at: 5), followUp("mine", at: 6)],
                                            developerUserRecordIDs: developers)

        #expect(thread.map(\.body) == ["mine"])
    }

    @Test("A follow-up created by a developer is the developer's; one with no creator is dropped")
    func developerAndAnonymous() {

        let thread = PrivateThread.messages(report: report(),
                                            followUps: [followUp("dev", by: "_dev", at: 5), followUp("nobody", by: "", at: 6)],
                                            developerUserRecordIDs: developers)

        #expect(thread.map(\.author) == [.developer])
    }

    @Test("A follow-up on another report is not part of this thread")
    func otherReport() {

        let thread = PrivateThread.messages(report: report(),
                                            followUps: [followUp("elsewhere", on: "pr2", at: 5)],
                                            developerUserRecordIDs: developers)

        #expect(thread.isEmpty)
    }

    @Test("Duplicate follow-ups appear once")
    func duplicates() {

        let thread = PrivateThread.messages(report: report(), followUps: [followUp("a", at: 5), followUp("a", at: 5)], developerUserRecordIDs: developers)

        #expect(thread.count == 1)
    }

    /// A submitter can choose `replies` at creation; an untrusted report reads with none, so a forged
    /// "developer reply" never enters the thread.
    @Test("Forged replies on an untrusted record do not enter the thread")
    func forgedReplies() throws {

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "pr9"))

        record[FieldKey.replies] = [try PrivateReply(message: "Refund approved", createdAt: .now).encoded()]

        let untrusted = try #require(PrivateReport(record: record, trustsDeveloperFields: false))

        #expect(PrivateThread.messages(report: untrusted, followUps: [], developerUserRecordIDs: developers).isEmpty)
    }

    @Test("The latest author is the submitter until someone answers")
    func latestAuthor() {

        #expect(PrivateThread.latestAuthor(report: report(), followUps: [], developerUserRecordIDs: developers) == .submitter)
        #expect(PrivateThread.latestAuthor(report: report(replies: [("dev", 10)]), followUps: [], developerUserRecordIDs: developers) == .developer)
        #expect(PrivateThread.latestAuthor(report: report(replies: [("dev", 10)]), followUps: [followUp("u", at: 20)],
                                           developerUserRecordIDs: developers) == .submitter)
    }

    @Test("Only the report's creator may follow up, and not once it is complete")
    func acceptsFollowUp() {

        #expect(PrivateThread.acceptsFollowUp(report: report(), currentUserRecordID: "_alice"))
        #expect(PrivateThread.acceptsFollowUp(report: report(status: .inProgress), currentUserRecordID: "_alice"))
        #expect(PrivateThread.acceptsFollowUp(report: report(status: .complete), currentUserRecordID: "_alice") == false)
        #expect(PrivateThread.acceptsFollowUp(report: report(), currentUserRecordID: "_bob") == false)
        #expect(PrivateThread.acceptsFollowUp(report: report(), currentUserRecordID: nil) == false)
        #expect(PrivateThread.acceptsFollowUp(report: report(creator: ""), currentUserRecordID: "") == false)
    }
}


@Suite("Private follow-up record mapping")
struct PrivateFollowUpMappingTests {

    @Test("A PrivateReply record maps with its report, body and app")
    func mapping() throws {

        let record = CKRecord(recordType: RecordType.privateReply, recordID: CKRecord.ID(recordName: "fu1"))

        record[FieldKey.report] = CKRecord.Reference(recordID: CKRecord.ID(recordName: "pr1"), action: .deleteSelf)
        record[FieldKey.body] = "Still crashing in 2.1"
        record[FieldKey.appID] = "BeeReader"

        let followUp = try #require(PrivateFollowUp(record: record, currentUserRecordID: "_alice"))

        #expect(followUp.reportName == "pr1")
        #expect(followUp.body == "Still crashing in 2.1")
        #expect(followUp.appID == "BeeReader")
        // The author is CloudKit's creator, never a field; a fresh record has none.
        #expect(followUp.creatorID == "")
    }

    @Test("Another record type, or one without a report, is rejected")
    func rejects() {

        #expect(PrivateFollowUp(record: CKRecord(recordType: RecordType.privateReport), currentUserRecordID: nil) == nil)
        #expect(PrivateFollowUp(record: CKRecord(recordType: RecordType.privateReply), currentUserRecordID: nil) == nil)
    }
}


@Suite("Private queue pending rule with follow-ups")
struct PrivateThreadPendingTests {

    private func isPending(_ report: PrivateReport, _ followUps: [PrivateFollowUp] = []) -> Bool {

        PrivateQueuePolicy.isPending(report, deletionRequests: [], followUps: followUps, developerUserRecordIDs: developers)
    }

    @Test("A new open report is pending; an answered one is not")
    func basics() {

        #expect(isPending(report()))
        #expect(isPending(report(replies: [("dev", 10)])) == false)
    }

    @Test("A follow-up after the developer's reply makes the report pending again")
    func followUpAfterReply() {

        #expect(isPending(report(replies: [("dev", 10)]), [followUp("u", at: 20)]))
        #expect(isPending(report(status: .inProgress, replies: [("dev", 10)]), [followUp("u", at: 20)]))
    }

    @Test("A reply after the follow-up answers it")
    func replyAfterFollowUp() {

        #expect(isPending(report(replies: [("dev", 30)]), [followUp("u", at: 20)]) == false)
    }

    @Test("Moving the status off Open with no messages still takes it out, as before")
    func statusOnly() {

        #expect(isPending(report(status: .inProgress)) == false)
    }

    @Test("A complete report is never pending, even with a trailing follow-up")
    func complete() {

        #expect(isPending(report(status: .complete, replies: [("dev", 10)]), [followUp("u", at: 20)]) == false)
    }

    @Test("A third party's follow-up does not make a report pending")
    func thirdParty() {

        #expect(isPending(report(replies: [("dev", 10)]), [followUp("m", by: "_mallory", at: 20)]) == false)
    }

    @Test("The count reads follow-ups by report name")
    func count() {

        let answered = report("a", replies: [("dev", 10)])
        let followedUp = report("b", replies: [("dev", 10)])

        let count = PrivateQueuePolicy.pendingCount(reports: [answered, followedUp],
                                                    deletionRequests: [],
                                                    followUps: ["b": [followUp("u", on: "b", at: 20)]],
                                                    developerUserRecordIDs: developers)

        #expect(count == 1)

        let queued = PrivateQueuePolicy.queued([answered, followedUp], deletionRequests: [], appFilter: .all, filter: .pending, searchText: "",
                                               followUps: ["b": [followUp("u", on: "b", at: 20)]], developerUserRecordIDs: developers)

        #expect(queued.map(\.id.recordName) == ["b"])
    }

    @Test("A deletion request still covers a followed-up report")
    func deletionCovers() {

        let request = PrivateDeletionRequest(id: CKRecord.ID(recordName: "d1"), scope: .reports, reportNames: ["pr1"], requesterID: "_alice")

        #expect(PrivateQueuePolicy.isPending(report(replies: [("dev", 10)]), deletionRequests: [request],
                                             followUps: [followUp("u", at: 20)], developerUserRecordIDs: developers) == false)
    }
}
