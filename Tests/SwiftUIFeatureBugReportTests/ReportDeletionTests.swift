//
//  ReportDeletionTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("Deleting a whole private report")
struct ReportDeletionTests {

    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name) }

    private func request(_ name: String, _ scope: PrivateDeletionScope, _ reports: [String], by requester: String) -> PrivateDeletionRequest {

        PrivateDeletionRequest(id: id(name), scope: scope, reportNames: reports, requesterID: requester)
    }

    @Test("Every follow-up on the report goes, whoever wrote it, and nothing on other reports")
    func followUps() {

        let followUps: [(id: CKRecord.ID, reportName: String)] = [
            (id: id("f1"), reportName: "r1"),
            (id: id("f2"), reportName: "r2"),
            (id: id("f3"), reportName: "r1"),
            (id: id("f1"), reportName: "r1"),
        ]

        #expect(PrivateReportDeletion.followUpIDs(followUps, reportName: "r1") == [id("f1"), id("f3")])
        #expect(PrivateReportDeletion.followUpIDs(followUps, reportName: "r3").isEmpty)
        #expect(PrivateReportDeletion.followUpIDs([], reportName: "r1").isEmpty)
    }

    @Test("Only the sender's own requests naming just this report are fulfilled")
    func fulfilledRequests() {

        let requests = [
            request("only", .reports, ["r1"], by: "_alice"),
            request("repeated", .reports, ["r1", "r1"], by: "_alice"),
            request("several", .reports, ["r1", "r2"], by: "_alice"),
            request("other", .reports, ["r2"], by: "_alice"),
            request("all", .all, [], by: "_alice"),
            request("someoneElse", .reports, ["r1"], by: "_mallory"),
            request("empty", .reports, [], by: "_alice"),
        ]

        let fulfilled = PrivateReportDeletion.fulfilledRequests(requests, reportName: "r1", reportCreator: "_alice")

        #expect(fulfilled.map(\.id.recordName) == ["only", "repeated"])
    }

    @Test("An `.all` request is never pruned")
    func allRequestsKept() {

        let requests = [request("all", .all, ["r1"], by: "_alice")]

        #expect(PrivateReportDeletion.fulfilledRequests(requests, reportName: "r1", reportCreator: "_alice").isEmpty)
    }

    @Test("A report with no known creator fulfils nothing")
    func unknownCreator() {

        let requests = [request("blank", .reports, ["r1"], by: "")]

        #expect(PrivateReportDeletion.fulfilledRequests(requests, reportName: "r1", reportCreator: "").isEmpty)
    }

    @Test("File copies are matched by report and numeric index only")
    func cachedFileDirectories() {

        #expect(PrivateReportDeletion.isCachedFileDirectory("ABC-0", reportName: "ABC"))
        #expect(PrivateReportDeletion.isCachedFileDirectory("ABC-12", reportName: "ABC"))

        // Another report whose name starts with this one's.
        #expect(PrivateReportDeletion.isCachedFileDirectory("ABC-DEF-0", reportName: "ABC") == false)
        #expect(PrivateReportDeletion.isCachedFileDirectory("ABC-", reportName: "ABC") == false)
        #expect(PrivateReportDeletion.isCachedFileDirectory("ABCD-0", reportName: "ABC") == false)
        #expect(PrivateReportDeletion.isCachedFileDirectory("XYZ-0", reportName: "ABC") == false)

        // Named the way `copyOut` names them, after sanitising.
        let sanitized = FileAttachmentName.sanitized("a/b", fallback: "report")

        #expect(PrivateReportDeletion.isCachedFileDirectory("\(sanitized)-3", reportName: "a/b"))
    }

    @Test("Only image copies made in the temporary directory are removed")
    func cachedImages() {

        let temporary = URL(fileURLWithPath: "/tmp/sandbox", isDirectory: true)

        #expect(PrivateReportDeletion.isCachedImageCopy(temporary.appendingPathComponent("feedback-asset-1234.jpg"),
                                                        temporaryDirectory: temporary))

        #expect(PrivateReportDeletion.isCachedImageCopy(temporary.appendingPathComponent("photo.jpg"),
                                                        temporaryDirectory: temporary) == false)
        #expect(PrivateReportDeletion.isCachedImageCopy(URL(fileURLWithPath: "/Users/me/feedback-asset-1.jpg"),
                                                        temporaryDirectory: temporary) == false)
        #expect(PrivateReportDeletion.isCachedImageCopy(URL(string: "https://example.com/feedback-asset-1.jpg")!,
                                                        temporaryDirectory: temporary) == false)
    }

}
