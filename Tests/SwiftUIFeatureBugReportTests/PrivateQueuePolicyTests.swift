//
//  PrivateQueuePolicyTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("Private queue pending rule")
struct PrivateQueuePolicyTests {

    private func report(_ name: String,
                        status: RequestStatus = .open,
                        replies: Int = 0,
                        creator: String = "_alice",
                        appID: String? = nil,
                        title: String = "",
                        body: String = "") -> PrivateReport {

        PrivateReport(id: CKRecord.ID(recordName: name),
                      title: title,
                      body: body,
                      status: status,
                      creatorID: creator,
                      appID: appID,
                      replies: (0..<replies).map { PrivateReply(message: "r\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) })
    }

    private func deletion(_ name: String,
                          scope: PrivateDeletionScope = .reports,
                          reports: [String] = [],
                          requester: String = "_alice") -> PrivateDeletionRequest {

        PrivateDeletionRequest(id: CKRecord.ID(recordName: name), scope: scope, reportNames: reports, requesterID: requester)
    }

    @Test("Only open and unanswered counts as awaiting the developer")
    func awaiting() {

        #expect(PrivateQueuePolicy.isAwaitingDeveloper(status: .open, replyCount: 0))
        #expect(PrivateQueuePolicy.isAwaitingDeveloper(status: .open, replyCount: 1) == false)

        for status in RequestStatus.allCases where status != .open {

            #expect(PrivateQueuePolicy.isAwaitingDeveloper(status: status, replyCount: 0) == false)
        }
    }

    @Test("A report covered by its creator's deletion request is not counted twice")
    func deletionCoveredReportIsNotPending() {

        let covered = report("pr1")
        let request = deletion("d1", reports: ["pr1"])

        #expect(PrivateQueuePolicy.isPending(covered, deletionRequests: []))
        #expect(PrivateQueuePolicy.isPending(covered, deletionRequests: [request]) == false)
        #expect(PrivateQueuePolicy.pendingCount(reports: [covered], deletionRequests: [request]) == 1)
    }

    @Test("Someone else's deletion request does not hide a report")
    func otherRequesterDoesNotCover() {

        let mine = report("pr1", creator: "_alice")
        let theirs = deletion("d1", scope: .all, requester: "_bob")

        #expect(PrivateQueuePolicy.isPending(mine, deletionRequests: [theirs]))
        #expect(PrivateQueuePolicy.pendingCount(reports: [mine], deletionRequests: [theirs]) == 2)
    }

    @Test("Pending count adds unanswered open reports and every deletion request")
    func count() {

        let reports = [
            report("open"),
            report("answered", replies: 1),
            report("inProgress", status: .inProgress),
            report("complete", status: .complete),
            report("open2", creator: "_bob")
        ]

        #expect(PrivateQueuePolicy.pendingCount(reports: reports, deletionRequests: []) == 2)
        #expect(PrivateQueuePolicy.pendingCount(reports: reports,
                                                deletionRequests: [deletion("d1", requester: "_carol")]) == 3)
        #expect(PrivateQueuePolicy.pendingCount(reports: [], deletionRequests: []) == 0)
    }

    @Test("The app filter narrows reports but not deletion requests")
    func appFilter() {

        let reports = [report("a", appID: "BeeDay"), report("b", appID: "BeeTunes"), report("c")]
        let requests = [deletion("d1", requester: "_carol")]

        #expect(PrivateQueuePolicy.pendingCount(reports: reports, deletionRequests: requests, appFilter: .all) == 4)
        #expect(PrivateQueuePolicy.pendingCount(reports: reports, deletionRequests: requests, appFilter: .app("BeeDay")) == 2)
        #expect(PrivateQueuePolicy.pendingCount(reports: reports, deletionRequests: requests, appFilter: .unscoped) == 2)
    }

    @Test("A report a developer never wrote to counts as pending")
    func untrustedReportIsPending() throws {

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "forged"))

        record[FieldKey.status] = RequestStatus.complete.rawValue
        record[FieldKey.replies] = [try PrivateReply(message: "Fake", createdAt: .now).encoded()]

        let report = try #require(PrivateReport(record: record, trustsDeveloperFields: false))

        #expect(PrivateQueuePolicy.isPending(report, deletionRequests: []))
    }

    @Test("The Pending filter lists exactly what the badge counts")
    func pendingFilterMatchesCount() {

        let reports = [report("open"), report("answered", replies: 1), report("covered", creator: "_bob")]
        let requests = [deletion("d1", reports: ["covered"], requester: "_bob")]

        let pending = PrivateQueuePolicy.queued(reports, deletionRequests: requests, appFilter: .all, filter: .pending, searchText: "")
        let all = PrivateQueuePolicy.queued(reports, deletionRequests: requests, appFilter: .all, filter: .all, searchText: "")

        #expect(pending.map(\.id.recordName) == ["open"])
        #expect(all.count == 3)
        #expect(pending.count + requests.count == PrivateQueuePolicy.pendingCount(reports: reports, deletionRequests: requests))
    }

    @Test("Search matches title, body and sender, case-insensitively")
    func search() {

        let crash = report("pr1", creator: "_alice", title: "Crash on launch", body: "Every time")

        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: ""))
        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: "  "))
        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: "CRASH"))
        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: "every"))
        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: "_ali"))
        #expect(PrivateQueuePolicy.matchesSearch(crash, searchText: "freeze") == false)
    }
}
