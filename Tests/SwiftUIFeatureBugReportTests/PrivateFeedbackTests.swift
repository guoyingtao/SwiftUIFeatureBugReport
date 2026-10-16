//
//  PrivateFeedbackTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("Private feedback policy")
struct PrivateFeedbackPolicyTests {

    @Test("Disabled never offers the toggle and never goes private")
    func disabled() {

        #expect(PrivateFeedbackPolicy.offersToggle(mode: .disabled) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .disabled, type: .bug, hasAttachments: true, userChoice: true) == false)
    }

    @Test("Optional follows the user's choice and never forces")
    func optional() {

        #expect(PrivateFeedbackPolicy.offersToggle(mode: .optional))
        #expect(PrivateFeedbackPolicy.isForced(mode: .optional, type: .bug, hasAttachments: true) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .optional, type: .bug, hasAttachments: false, userChoice: false) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .optional, type: .feature, hasAttachments: false, userChoice: true))
    }

    @Test("Bugs and attachments are forced private; plain feature requests are not")
    func bugsAndAttachments() {

        #expect(PrivateFeedbackPolicy.isForced(mode: .bugsAndAttachments, type: .bug, hasAttachments: false))
        #expect(PrivateFeedbackPolicy.isForced(mode: .bugsAndAttachments, type: .feature, hasAttachments: true))
        #expect(PrivateFeedbackPolicy.isForced(mode: .bugsAndAttachments, type: .feature, hasAttachments: false) == false)

        #expect(PrivateFeedbackPolicy.isPrivate(mode: .bugsAndAttachments, type: .feature, hasAttachments: false, userChoice: false) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .bugsAndAttachments, type: .feature, hasAttachments: false, userChoice: true))
    }

    @Test("Private submissions may carry images even when public attachments are off")
    func images() {

        #expect(PrivateFeedbackPolicy.allowsImages(publicAttachmentsAllowed: false, isPrivate: true))
        #expect(PrivateFeedbackPolicy.allowsImages(publicAttachmentsAllowed: false, isPrivate: false) == false)
        #expect(PrivateFeedbackPolicy.allowsImages(publicAttachmentsAllowed: true, isPrivate: false))
    }

    @Test("The configuration defaults to disabled, so an older schema keeps working")
    func defaultIsDisabled() {

        let configuration = FeedbackConfiguration(containerIdentifier: "iCloud.test")

        #expect(configuration.privateFeedback == .disabled)
    }
}


@Suite("Private report record mapping")
struct PrivateReportMappingTests {

    @Test("Every field round-trips out of a record")
    func readsEveryField() throws {

        let reply = try PrivateReply(message: "Fixed in 2.1", createdAt: Date(timeIntervalSince1970: 2_000)).encoded()

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "pr1"))

        record[FieldKey.title] = "Crash on launch"
        record[FieldKey.body] = "Screenshot attached."
        record[FieldKey.kind] = FeedbackType.bug.rawValue
        record[FieldKey.status] = RequestStatus.inProgress.rawValue
        record[FieldKey.creatorID] = "_user1"
        record[FieldKey.replies] = [reply]
        record[FieldKey.payload] = "{\"plan\":\"pro\"}"
        record[FieldKey.appVersion] = "1.1.0"
        record[FieldKey.buildNumber] = "15"
        record[FieldKey.osVersion] = "26.0"
        record[FieldKey.deviceModel] = "iPhone17,1"
        record[FieldKey.platform] = "iOS"
        record[FieldKey.lastActivityAt] = Date(timeIntervalSince1970: 1_000)

        let report = try #require(PrivateReport(record: record))

        #expect(report.title == "Crash on launch")
        #expect(report.body == "Screenshot attached.")
        #expect(report.kind == .bug)
        #expect(report.status == .inProgress)
        #expect(report.creatorID == "_user1")
        #expect(report.metadata == ["plan": "pro"])
        #expect(report.environment.deviceModel == "iPhone17,1")
        #expect(report.lastActivityAt == Date(timeIntervalSince1970: 1_000))
        #expect(report.replies == [PrivateReply(message: "Fixed in 2.1", createdAt: Date(timeIntervalSince1970: 2_000))])
    }

    @Test("A record of another type is rejected")
    func rejectsOtherTypes() {

        #expect(PrivateReport(record: CKRecord(recordType: RecordType.request)) == nil)
    }

    @Test("Unreadable reply entries are skipped and the rest are sorted oldest first")
    func replyDecoding() throws {

        let newer = try PrivateReply(message: "Second", createdAt: Date(timeIntervalSince1970: 3_000)).encoded()
        let older = try PrivateReply(message: "First", createdAt: Date(timeIntervalSince1970: 1_000)).encoded()

        let replies = PrivateReply.decode([newer, "not json", older])

        #expect(replies.map(\.message) == ["First", "Second"])
    }
}


@Suite("Private reports in account data")
struct PrivateReportAccountDataTests {

    /// Without this, a user whose only data is private reports would see the delete button disabled.
    @Test("Private reports alone make the counts non-empty")
    func privateReportsCount() {

        #expect(MyDataCounts().isEmpty)
        #expect(MyDataCounts(privateReports: 1).isEmpty == false)
    }

    @Test("Only an unknown item on the first page means the record type is missing")
    func missingRecordType() {

        let unknown = CKError(.unknownItem)

        #expect(AccountDataService.isMissingRecordType(unknown, isFirstPage: true))
        #expect(AccountDataService.isMissingRecordType(unknown, isFirstPage: false) == false)
        #expect(AccountDataService.isMissingRecordType(CKError(.networkFailure), isFirstPage: true) == false)
    }
}
