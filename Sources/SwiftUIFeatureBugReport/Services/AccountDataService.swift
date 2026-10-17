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

    /// The app scope "My data" works in: the configuration's, so counts and deletion cover only this
    /// app's records when `appID` is set, and the whole account when it is `nil`. See `AppDataScoping`.
    public var scope: AppScope { container.configuration.appScope }

    /// Whether counts and deletion are limited to this app (`appID` set) rather than account-wide.
    public var isAppScoped: Bool { scope.appID != nil }

    public func loadCounts() async {

        guard let me = container.currentUserRecordID else { return }

        isLoading = true
        error = nil

        defer { isLoading = false }

        let scope = self.scope

        async let requests = recordIDs(ofType: RecordType.request, createdBy: me, scope: scope).count
        async let votes = recordIDs(ofType: RecordType.vote, createdBy: me, scope: scope).count
        async let comments = commentRecordIDs(createdBy: me, scope: scope).count
        async let reports = recordIDs(ofType: RecordType.report, createdBy: me, scope: scope).count
        async let privateStatus = privateStatus(createdBy: me, scope: scope)

        let (privateReports, privateDeletionRequested) = await privateStatus

        counts = MyDataCounts(requests: await requests,
                              votes: await votes,
                              comments: await comments,
                              reports: await reports,
                              privateReports: privateReports,
                              privateDeletionRequested: privateDeletionRequested)
    }

    /// Real deletion (§6.8).
    ///
    /// **Per app when `appID` is set.** Only records of this app are deleted - by the same rule the
    /// board uses, so unscoped legacy records go only if `includeUnscopedRecords` is on. Records without
    /// an `appID` of their own (replies, reports, follows) are scoped through the request they belong to.
    /// The user's data in other apps sharing the container stays, and is deleted from those apps. With
    /// `appID` `nil` this is account-wide, as before.
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

        await delete(creatorID: me, scope: scope)
    }

    /// The same operation the portal offers, keyed by `creatorID`, so a developer can act on a
    /// deletion request that arrived by email.
    ///
    /// `scope` defaults to `.unscoped`: the portal sees every app, and a developer honouring an
    /// erasure request should remove the person's data everywhere. "Delete my data" passes the app's
    /// own scope instead.
    public func delete(creatorID: String, scope: AppScope = .unscoped) async {

        isDeleting = true
        error = nil

        defer { isDeleting = false }

        do {

            // Every list is read *before* anything is deleted: once a request is gone its children can
            // no longer be traced to an app, and a per-app pass would miss or misplace them.
            let requestIDs = try await scopedRecordIDs(ofType: RecordType.request, createdBy: creatorID, scope: scope)
            let commentIDs = container.configuration.allowComments
                ? try await scopedRecordIDs(ofType: RecordType.comment, createdBy: creatorID, scope: scope)
                : []
            let reportIDs = try await scopedRecordIDs(ofType: RecordType.report, createdBy: creatorID, scope: scope)
            let followIDs = try await scopedRecordIDs(ofType: RecordType.follow, createdBy: creatorID, scope: scope)

            // Requests first: `.deleteSelf` cascades their votes, comments, reports, activity and
            // metadata, so the later passes have less to do.
            try await CloudKitBatch.delete(requestIDs, in: database)

            // Then the text this user left on *other people's* requests. Votes are not in this list -
            // see the note above.
            try await CloudKitBatch.delete(commentIDs, in: database)
            try await CloudKitBatch.delete(reportIDs, in: database)

            // Follows go, unlike votes. A follow changes nothing anyone else can see - it only says
            // this person wanted to hear about a request - so removing it rewrites no shared state,
            // and leaving it would keep notifying an account whose data is supposed to be gone.
            try await CloudKitBatch.delete(followIDs, in: database)

            // Private reports are this user's own text and images, handled whatever `privateFeedback`
            // says now: turning new submissions off must not leave earlier ones undeletable. A schema
            // without the record type simply has none.
            //
            // Only the `dev` role may delete them - `_creator` has READ only, so a submitter cannot
            // rewrite the developer's replies. A submitter therefore *requests* deletion, which the
            // developer processes from the private reports queue. Their follow-ups (`PrivateReply`, also
            // `_creator` READ only) are deleted when the developer processes that request, and cascade
            // with the reports. Per app, that request names this
            // app's reports rather than asking for `.all`.
            let privateIDs = try await scopedRecordIDs(ofType: RecordType.privateReport, createdBy: creatorID,
                                                       scope: scope, throwsOnMissingType: false)
            var deletionRequested = false

            if container.isDeveloper {

                // Their follow-ups on private reports (`PrivateReply`) go first. They also cascade with
                // their reports, but follow-ups pointing elsewhere would not. Scoped by their own
                // `appID`, which is their report's. A schema without the type has none.
                let followUpIDs = try await scopedRecordIDs(ofType: RecordType.privateReply, createdBy: creatorID,
                                                            scope: scope, throwsOnMissingType: false)

                try await CloudKitBatch.delete(followUpIDs, in: database)
                try await CloudKitBatch.delete(privateIDs, in: database)

                let pending = try await deletionRequests(createdBy: creatorID)
                let fulfilled = AppDataScoping.fulfilledDeletionRequests(pending,
                                                                         deletedReportNames: Set(privateIDs.map(\.recordName)),
                                                                         scope: scope)

                try await CloudKitBatch.delete(fulfilled.map(\.id), in: database)
            }
            else if creatorID == container.currentUserRecordID,
                    let ask = AppDataScoping.deletionRequest(scope: scope, scopedReportNames: privateIDs.map(\.recordName)) {

                try await PrivateReportService.saveDeletionRequest(scope: ask.scope,
                                                                   reportNames: ask.reportNames,
                                                                   requesterID: creatorID,
                                                                   in: database)
                deletionRequested = true
            }

            counts = MyDataCounts(requests: 0,
                                  votes: await recordIDs(ofType: RecordType.vote, createdBy: creatorID, scope: scope).count,
                                  comments: 0,
                                  reports: 0,
                                  privateReports: deletionRequested ? privateIDs.count : 0,
                                  privateDeletionRequested: deletionRequested)
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)
        }
    }

    // MARK: - Queries

    /// Queried by CloudKit's own creator reference rather than by our denormalised `creatorID`, so it
    /// also catches record types that have no such field.
    private func commentRecordIDs(createdBy userRecordName: String, scope: AppScope) async -> [CKRecord.ID] {

        guard container.configuration.allowComments else { return [] }

        return await recordIDs(ofType: RecordType.comment, createdBy: userRecordName, scope: scope)
    }

    /// For counts: failures surface in `error` and read as none.
    private func recordIDs(ofType recordType: String, createdBy userRecordName: String, scope: AppScope) async -> [CKRecord.ID] {

        do {

            return try await scopedRecordIDs(ofType: recordType, createdBy: userRecordName, scope: scope)
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)

            return []
        }
    }

    /// Private report count and pending-deletion state for this scope. Failures surface and read as none.
    private func privateStatus(createdBy userRecordName: String, scope: AppScope) async -> (Int, Bool) {

        do {

            let reports = try await scopedRecordIDs(ofType: RecordType.privateReport, createdBy: userRecordName,
                                                    scope: scope, throwsOnMissingType: false)
            let pending = try await deletionRequests(createdBy: userRecordName)
            let requested = AppDataScoping.hasPendingDeletion(pending,
                                                              requesterID: userRecordName,
                                                              scopedReportNames: Set(reports.map(\.recordName)),
                                                              scope: scope)

            return (reports.count, requested)
        }
        catch {

            self.error = CloudKitErrorHandler.classify(error)

            return (0, false)
        }
    }

    /// The user's `PrivateReportDeletionRequest` records, all pages. These carry no `appID`; per-app
    /// handling goes by the report names they list - see `AppDataScoping`.
    private func deletionRequests(createdBy userRecordName: String) async throws -> [PrivateDeletionRequest] {

        let records = try await fetchRecords(ofType: RecordType.privateReportDeletionRequest,
                                             createdBy: userRecordName,
                                             desiredKeys: PrivateDeletionRequest.desiredKeys,
                                             throwsOnMissingType: false)

        return records.compactMap { PrivateDeletionRequest(record: $0, currentUserRecordID: container.currentUserRecordID) }
    }

    /// The IDs of `recordType` records the user created that fall in `scope`.
    ///
    /// Account-wide this is a plain creator query. Per app it also reads each record's `appID` and
    /// `request`, then the `appID` of every parent request a record has to borrow its app from.
    private func scopedRecordIDs(ofType recordType: String,
                                 createdBy userRecordName: String,
                                 scope: AppScope,
                                 throwsOnMissingType: Bool = true) async throws -> [CKRecord.ID] {

        guard AppDataScoping.needsParentLookup(scope) else {

            return try await fetchRecords(ofType: recordType, createdBy: userRecordName, desiredKeys: [],
                                          throwsOnMissingType: throwsOnMissingType).map(\.recordID)
        }

        let records = try await fetchRecords(ofType: recordType, createdBy: userRecordName,
                                             desiredKeys: [FieldKey.appID, FieldKey.request],
                                             throwsOnMissingType: throwsOnMissingType)

        var byName: [String: CKRecord.ID] = [:]

        let scoped = records.map { record in

            byName[record.recordID.recordName] = record.recordID

            return AppScopedRecord(name: record.recordID.recordName,
                                   ownAppID: record[FieldKey.appID] as? String,
                                   parentRequestName: (record[FieldKey.request] as? CKRecord.Reference)?.recordID.recordName)
        }

        let parentAppIDs = try await requestAppIDs(AppDataScoping.parentNamesToResolve(scoped))

        return AppDataScoping.filter(scoped, parentAppIDs: parentAppIDs, scope: scope).compactMap { byName[$0.name] }
    }

    /// `appID` of each named request that exists and has one. A request CloudKit confirms is gone is
    /// left out, so its orphaned children read as unscoped. Any other per-record failure throws: guessing
    /// would let a transient error put another app's records in (or this app's records out of) scope.
    private func requestAppIDs(_ names: Set<String>) async throws -> [String: String] {

        var result: [String: String] = [:]

        for chunk in Array(names).chunked(into: CloudKitBatch.maximumOperationSize) {

            let fetched = try await database.records(for: chunk.map { CKRecord.ID(recordName: $0) }, desiredKeys: [FieldKey.appID])

            for (id, outcome) in fetched {

                let record: CKRecord

                switch outcome {

                case .success(let fetchedRecord):
                    record = fetchedRecord

                case .failure(let error):
                    if CloudKitErrorHandler.isRecordMissing(error) { continue }
                    throw error
                }

                guard let appID = AppScope.normalized(record[FieldKey.appID] as? String) else { continue }

                result[id.recordName] = appID
            }
        }

        return result
    }

    /// Every record of `recordType` the user created, all pages.
    ///
    /// Throws, so a failed read stops a deletion instead of reporting success with data still stored.
    /// With `throwsOnMissingType` off, a schema that never had the type (CloudKit answers `.unknownItem`
    /// to the first query) reads as no records - used for `PrivateReport` and its deletion requests.
    private func fetchRecords(ofType recordType: String,
                              createdBy userRecordName: String,
                              desiredKeys: [String],
                              throwsOnMissingType: Bool) async throws -> [CKRecord] {

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: userRecordName), action: .none)
        let predicate = NSPredicate(format: "creatorUserRecordID == %@", reference)

        var collected: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys)
                }
                else {

                    page = try await database.records(matching: CKQuery(recordType: recordType, predicate: predicate),
                                                      desiredKeys: desiredKeys)
                }

                // A record that vanished between query and load is skipped; any other per-record
                // failure throws, so a deletion never reports completion with that record still stored.
                for (_, result) in page.matchResults {

                    switch result {

                    case .success(let record):
                        collected.append(record)

                    case .failure(let recordError):
                        if CloudKitErrorHandler.isRecordMissing(recordError) { continue }
                        throw recordError
                    }
                }

                cursor = page.queryCursor
            }
            catch {

                if !throwsOnMissingType, Self.isMissingRecordType(error, isFirstPage: collected.isEmpty && cursor == nil) { return [] }

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
