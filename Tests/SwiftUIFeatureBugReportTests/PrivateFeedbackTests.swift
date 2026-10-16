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


@Suite("Private report deletion requests")
struct PrivateDeletionPolicyTests {

    private func request(_ scope: PrivateDeletionScope, _ names: [String] = [], requester: String = "_user1") -> PrivateDeletionRequest {

        let record = CKRecord(recordType: RecordType.privateReportDeletionRequest,
                              recordID: CKRecord.ID(recordName: "privdel_\(UUID().uuidString)"))

        record[FieldKey.scope] = scope.rawValue
        record[FieldKey.reportNames] = names

        // A freshly made record has no creator, so `requesterID` is empty here; the policy functions
        // below take the requester explicitly.
        return PrivateDeletionRequest(record: record, currentUserRecordID: requester)!
    }

    @Test("A request for named reports marks only those reports")
    func namedReports() {

        let pending = [request(.reports, ["a", "b"])]

        #expect(PrivateDeletionPolicy.isPending(reportName: "a", in: pending))
        #expect(PrivateDeletionPolicy.isPending(reportName: "c", in: pending) == false)
    }

    @Test("An all-reports request marks every report; no request marks none")
    func allReports() {

        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", in: [request(.all)]))
        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", in: []) == false)
    }

    /// The security property: a request naming someone else's report must not get it deleted.
    @Test("Only reports created by the requester are deletable, once each")
    func ownership() {

        let deletable = PrivateDeletionPolicy.deletableReportNames(requested: ["mine", "theirs", "mine", "gone"],
                                                                   owners: ["mine": "_user1", "theirs": "_user2"],
                                                                   requesterID: "_user1")

        #expect(deletable == ["mine"])
        #expect(PrivateDeletionPolicy.deletableReportNames(requested: ["mine"], owners: ["mine": ""], requesterID: "").isEmpty)
    }

    @Test("CloudKit's current-user placeholder resolves to the signed-in user")
    func resolvesPlaceholder() {

        #expect(PrivateDeletionPolicy.resolvedCreator(CKCurrentUserDefaultName, currentUserRecordID: "_me") == "_me")
        #expect(PrivateDeletionPolicy.resolvedCreator("_other", currentUserRecordID: "_me") == "_other")
        #expect(PrivateDeletionPolicy.resolvedCreator(nil, currentUserRecordID: "_me") == nil)
    }

    @Test("Deletion record names are deterministic, so a second request collides")
    func deterministicNames() {

        #expect(RecordID.privateDeletion(report: "r1") == RecordID.privateDeletion(report: "r1"))
        #expect(RecordID.privateDeletionAll(user: "_u") != RecordID.privateDeletion(report: "_u"))
    }

    @Test("A pending deletion keeps the counts non-empty")
    func pendingCounts() {

        #expect(MyDataCounts(privateReports: 2, privateDeletionRequested: true).isEmpty == false)
    }
}
