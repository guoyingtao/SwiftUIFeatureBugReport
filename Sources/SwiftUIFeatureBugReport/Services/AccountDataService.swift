//
//  AccountDataService.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation
import Observation

/// Counts shown before the destructive action, so the confirmation says what is actually at stake.
public struct MyDataCounts: Sendable, Equatable {

    public var requests = 0
    public var votes = 0
    public var comments = 0
    public var reports = 0

    /// The user's own `PrivateReport` records. Zero when the record type is not in the schema.
    public var privateReports = 0

    /// The user has asked the developer to delete their private reports and it has not been done yet.
    /// A submitter cannot delete a `PrivateReport` themselves - see `PrivateDeletionRequest`.
    public var privateDeletionRequested = false

    public var isEmpty: Bool {

        requests == 0 && votes == 0 && comments == 0 && reports == 0 && privateReports == 0
    }
}

@Observable @MainActor public final class AccountDataService {

    public private(set) var counts = MyDataCounts()
    public private(set) var isLoading = false
    public private(set) var isDeleting = false
    public var error: FeedbackError?

    private let container: FeedbackContainer

    private var database: CKDatabase { container.database }

    public init(container: FeedbackContainer) {

        self.container = container
    }

    public func loadCounts() async {

        guard let me = container.currentUserRecordID else { return }

        isLoading = true
        error = nil

        defer { isLoading = false }

        async let requests = recordIDs(ofType: RecordType.request, createdBy: me).count
        async let votes = recordIDs(ofType: RecordType.vote, createdBy: me).count
        async let comments = commentRecordIDs(createdBy: me).count
        async let reports = recordIDs(ofType: RecordType.report, createdBy: me).count
        async let privateReports = privateReportCount(createdBy: me)
        async let privateDeletionRequested = hasPendingPrivateDeletion(createdBy: me)

        counts = MyDataCounts(requests: await requests,
                              votes: await votes,
                              comments: await comments,
                              reports: await reports,
                              privateReports: await privateReports,
                              privateDeletionRequested: await privateDeletionRequested)
    }

    /// Real deletion (§6.8).
    ///
    /// Deleting a request takes other people's votes and comments on it with it, because every child
    /// reference uses `.deleteSelf`. That is the intended behaviour - the point is honouring the
    /// request - and the confirmation dialog states it plainly rather than burying it.
    ///
    /// **Votes this user cast on other people's requests are deliberately left in place.** A vote is
    /// a bare reference with no content of its own, and removing them would silently rewrite other
    /// people's tallies. Free text the user wrote - their requests, replies and reports - all goes,
    /// and so do their follows, which are private to them and change nothing anyone else can see.
    /// Anyone who wants a specific vote gone can withdraw it from the request itself.
    public func deleteAllMyData() async {

        guard let me = container.currentUserRecordID else {

            error = .notSignedIn
            return
        }

        await delete(creatorID: me)
    }

    /// The same operation the portal offers, keyed by `creatorID`, so a developer can act on a
    /// deletion request that arrived by email.
    public func delete(creatorID: String) async {

        isDeleting = true
        error = nil

        defer { isDeleting = false }

        do {

            // Requests first: `.deleteSelf` cascades their votes, comments, reports, activity and
            // metadata, so the later passes have less to do.
            try await CloudKitBatch.delete(await recordIDs(ofType: RecordType.request, createdBy: creatorID), in: database)

            // Then the text this user left on *other people's* requests. Votes are not in this list -
            // see the note above.
            try await CloudKitBatch.delete(await commentRecordIDs(createdBy: creatorID), in: database)
            try await CloudKitBatch.delete(await recordIDs(ofType: RecordType.report, createdBy: creatorID), in: database)

            // Follows go, unlike votes. A follow changes nothing anyone else can see - it only says
            // this person wanted to hear about a request - so removing it rewrites no shared state,
            // and leaving it would keep notifying an account whose data is supposed to be gone.
            try await CloudKitBatch.delete(await recordIDs(ofType: RecordType.follow, createdBy: creatorID), in: database)

            // Private reports are this user's own text and images, handled whatever `privateFeedback`
            // says now: turning new submissions off must not leave earlier ones undeletable. A schema
            // without the record type simply has none.
            //
            // Only the `dev` role may delete them - `_creator` has READ only, so a submitter cannot
            // rewrite the developer's replies. A submitter therefore *requests* deletion, which the
            // developer processes from the private reports queue.
            let privateIDs = try await privateReportIDs(createdBy: creatorID)
            var deletionRequested = false

            if container.isDeveloper {

                try await CloudKitBatch.delete(privateIDs, in: database)
                try await CloudKitBatch.delete(try await deletionRequestIDs(createdBy: creatorID), in: database)
            }
            else if !privateIDs.isEmpty && creatorID == container.currentUserRecordID {

                try await PrivateReportService.saveDeletionRequest(scope: .all,
                                                                   reportNames: [],
                                                                   requesterID: creatorID,
                                                                   in: database)
                deletionRequested = true
            }

            counts = MyDataCounts(requests: 0,
                                  votes: await recordIDs(ofType: RecordType.vote, createdBy: creatorID).count,
                                  comments: 0,
                                  reports: 0,
                                  privateReports: deletionRequested ? privateIDs.count : 0,
                                  privateDeletionRequested: deletionRequested)
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)
        }
    }

    /// Queried by CloudKit's own creator reference rather than by our denormalised `creatorID`, so it
    /// also catches record types that have no such field.
    private func commentRecordIDs(createdBy userRecordName: String) async -> [CKRecord.ID] {

        guard container.configuration.allowComments else { return [] }

        return await recordIDs(ofType: RecordType.comment, createdBy: userRecordName)
    }

    private func recordIDs(ofType recordType: String, createdBy userRecordName: String) async -> [CKRecord.ID] {

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: userRecordName), action: .none)
        let predicate = NSPredicate(format: "creatorUserRecordID == %@", reference)

        var collected: [CKRecord.ID] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
                }
                else {

                    page = try await database.records(matching: CKQuery(recordType: recordType, predicate: predicate),
                                                      desiredKeys: [])
                }

                collected.append(contentsOf: page.matchResults.map { $0.0 })

                cursor = page.queryCursor
            }
            catch {

                self.error = CloudKitErrorHandler.classify(error)
                break
            }
        }
        while cursor != nil

        return collected
    }

    /// Counts the user's private reports for `MyDataView`. A missing record type counts as none; any
    /// other failure is surfaced and counts as none, like the other counts.
    private func privateReportCount(createdBy userRecordName: String) async -> Int {

        do {

            return try await privateReportIDs(createdBy: userRecordName).count
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)

            return 0
        }
    }

    /// Whether the user has a deletion request waiting for the developer. Failures surface and read
    /// as `false`; a schema without the record type has none.
    private func hasPendingPrivateDeletion(createdBy userRecordName: String) async -> Bool {

        do {

            let pending = try await deletionRequestIDs(createdBy: userRecordName)

            return !pending.isEmpty
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)

            return false
        }
    }

    /// The user's `PrivateReportDeletionRequest` records, all pages.
    private func deletionRequestIDs(createdBy userRecordName: String) async throws -> [CKRecord.ID] {

        try await throwingRecordIDs(ofType: RecordType.privateReportDeletionRequest, createdBy: userRecordName)
    }

    /// Every `PrivateReport` the user created, all pages.
    ///
    /// Unlike `recordIDs(ofType:createdBy:)` this **throws**, so a failed read stops a deletion instead
    /// of reporting success with the user's private text and images still stored. The one exception is
    /// a schema that never had `PrivateReport`: CloudKit answers a query for an unknown record type
    /// with `.unknownItem`, and that means there is nothing to delete.
    private func privateReportIDs(createdBy userRecordName: String) async throws -> [CKRecord.ID] {

        try await throwingRecordIDs(ofType: RecordType.privateReport, createdBy: userRecordName)
    }

    /// Like `recordIDs(ofType:createdBy:)`, but throws - except for a record type the schema does not
    /// have, which reads as no records.
    private func throwingRecordIDs(ofType recordType: String, createdBy userRecordName: String) async throws -> [CKRecord.ID] {

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: userRecordName), action: .none)
        let predicate = NSPredicate(format: "creatorUserRecordID == %@", reference)

        var collected: [CKRecord.ID] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
                }
                else {

                    page = try await database.records(matching: CKQuery(recordType: recordType, predicate: predicate),
                                                      desiredKeys: [])
                }

                collected.append(contentsOf: page.matchResults.map { $0.0 })

                cursor = page.queryCursor
            }
            catch {

                if Self.isMissingRecordType(error, isFirstPage: collected.isEmpty && cursor == nil) { return [] }

                throw error
            }
        }
        while cursor != nil

        return collected
    }

    /// Only the very first query can mean "this record type does not exist". Once a page has come
    /// back the type evidently exists, so a later `.unknownItem` is a real failure.
    nonisolated static func isMissingRecordType(_ error: Error, isFirstPage: Bool) -> Bool {

        CloudKitErrorHandler.isMissingRecordType(error, isFirstPage: isFirstPage)
    }
}
