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

        let report = try #require(PrivateReport(record: record, trustsDeveloperFields: true))

        #expect(report.title == "Crash on launch")
        #expect(report.body == "Screenshot attached.")
        #expect(report.kind == .bug)
        #expect(report.status == .inProgress)
        // The sender comes from CloudKit's creator, never the client-written field; a fresh record has none.
        #expect(report.creatorID == "")
        #expect(report.metadata == ["plan": "pro"])
        #expect(report.environment.deviceModel == "iPhone17,1")
        #expect(report.lastActivityAt == Date(timeIntervalSince1970: 1_000))
        #expect(report.replies == [PrivateReply(message: "Fixed in 2.1", createdAt: Date(timeIntervalSince1970: 2_000))])
    }

    @Test("A record of another type is rejected")
    func rejectsOtherTypes() {

        #expect(PrivateReport(record: CKRecord(recordType: RecordType.request), trustsDeveloperFields: true) == nil)
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

        PrivateDeletionRequest(id: CKRecord.ID(recordName: UUID().uuidString), scope: scope, reportNames: names, requesterID: requester)
    }

    @Test("A request for named reports marks only those reports of its requester")
    func namedReports() {

        let pending = [request(.reports, ["a", "b"])]

        #expect(PrivateDeletionPolicy.isPending(reportName: "a", reportCreator: "_user1", in: pending))
        #expect(PrivateDeletionPolicy.isPending(reportName: "c", reportCreator: "_user1", in: pending) == false)
        #expect(PrivateDeletionPolicy.isPending(reportName: "a", reportCreator: "_user2", in: pending) == false)
    }

    @Test("An all-reports request marks only its requester's reports; no request marks none")
    func allReports() {

        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", reportCreator: "_user1", in: [request(.all)]))
        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", reportCreator: "_user2", in: [request(.all)]) == false)
        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", reportCreator: "", in: [request(.all, requester: "")]) == false)
        #expect(PrivateDeletionPolicy.isPending(reportName: "anything", reportCreator: "_user1", in: []) == false)
    }

    @Test("Only the requester's own pending requests cover a new one")
    func coverage() {

        let mine = [request(.reports, ["a", "b"])]

        #expect(PrivateDeletionPolicy.isCovered(scope: .reports, reportNames: ["a"], requesterID: "_user1", by: mine))
        #expect(PrivateDeletionPolicy.isCovered(scope: .reports, reportNames: ["c"], requesterID: "_user1", by: mine) == false)
        #expect(PrivateDeletionPolicy.isCovered(scope: .all, reportNames: [], requesterID: "_user1", by: mine) == false)
        #expect(PrivateDeletionPolicy.isCovered(scope: .reports, reportNames: ["z"], requesterID: "_user1", by: [request(.all)]))
        #expect(PrivateDeletionPolicy.isCovered(scope: .all, reportNames: [], requesterID: "_user2", by: [request(.all)]) == false)
    }

    @Test("Only private reports are deletion targets")
    func targetType() {

        #expect(PrivateDeletionPolicy.isDeletableTarget(recordType: RecordType.privateReport))
        #expect(PrivateDeletionPolicy.isDeletableTarget(recordType: RecordType.request) == false)
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

    @Test("A pending deletion keeps the counts non-empty")
    func pendingCounts() {

        #expect(MyDataCounts(privateReports: 2, privateDeletionRequested: true).isEmpty == false)
    }
}


@Suite("Developer-controlled fields on private reports")
struct PrivateReportTrustTests {

    private func forgedRecord() throws -> CKRecord {

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "pr2"))

        record[FieldKey.title] = "Crafted"
        record[FieldKey.status] = RequestStatus.complete.rawValue
        record[FieldKey.replies] = [try PrivateReply(message: "Refund approved", createdAt: .now).encoded()]

        return record
    }

    @Test("Untrusted records show no replies and the initial status")
    func untrustedFieldsIgnored() throws {

        let report = try #require(PrivateReport(record: try forgedRecord(), trustsDeveloperFields: false))

        #expect(report.title == "Crafted")
        #expect(report.replies.isEmpty)
        #expect(report.status == PrivateReportTrust.initialStatus)
    }

    /// A record nobody has modified yet - as in this test - has no last modifier, so it is not trusted.
    @Test("A record with no last modifier is not trusted")
    func noModifier() throws {

        let report = try #require(PrivateReport(record: try forgedRecord(), developerUserRecordIDs: ["_dev"], currentUserRecordID: "_dev"))

        #expect(report.replies.isEmpty)
    }

    @Test("Only a configured developer as last modifier is trusted")
    func trustRule() {

        let developers = ["_dev"]

        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: "_dev", developerUserRecordIDs: developers, currentUserRecordID: "_user"))
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: "_user", developerUserRecordIDs: developers, currentUserRecordID: "_user") == false)
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: nil, developerUserRecordIDs: developers, currentUserRecordID: "_dev") == false)
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: "_dev", developerUserRecordIDs: [], currentUserRecordID: "_dev") == false)
    }

    @Test("CloudKit's current-user placeholder resolves before comparing")
    func placeholder() {

        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: CKCurrentUserDefaultName,
                                             developerUserRecordIDs: ["_dev"],
                                             currentUserRecordID: "_dev"))
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: CKCurrentUserDefaultName,
                                             developerUserRecordIDs: ["_dev"],
                                             currentUserRecordID: "_user") == false)
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: CKCurrentUserDefaultName,
                                             developerUserRecordIDs: ["_dev"],
                                             currentUserRecordID: nil) == false)
    }
}


@Suite("Batch per-record failures")
struct CloudKitBatchFailureTests {

    @Test("Deleting an already missing record is not a failure")
    func missingDeleteIgnored() {

        #expect(CloudKitBatch.firstUnexpectedFailure(saveErrors: [], deleteErrors: [CKError(.unknownItem)]) == nil)
    }

    @Test("Any other delete failure is surfaced")
    func deleteFailureSurfaced() throws {

        let failure = try #require(CloudKitBatch.firstUnexpectedFailure(saveErrors: [],
                                                                        deleteErrors: [CKError(.unknownItem), CKError(.permissionFailure)]))

        #expect((failure as? CKError)?.code == .permissionFailure)
    }

    @Test("A save colliding with an existing record is deduplication, not failure")
    func duplicateSaveIgnored() {

        #expect(CloudKitBatch.firstUnexpectedFailure(saveErrors: [CKError(.serverRecordChanged)], deleteErrors: []) == nil)
    }

    @Test("Any other save failure is surfaced")
    func saveFailureSurfaced() {

        #expect(CloudKitBatch.firstUnexpectedFailure(saveErrors: [CKError(.networkFailure)], deleteErrors: []) != nil)
    }
}
