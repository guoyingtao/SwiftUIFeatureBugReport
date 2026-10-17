//
//  PrivateReportService.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation
import Observation

/// Private, developer-only submissions. See `PrivateReport` for the permission model.
@Observable @MainActor public final class PrivateReportService {

    /// The signed-in user's own private reports, newest first.
    public private(set) var myReports: [PrivateReport] = []

    /// Every private report, newest first. Only a developer can load this - for anyone else the
    /// `PrivateReport` grant returns nothing beyond their own records.
    public private(set) var allReports: [PrivateReport] = []

    /// The signed-in user's own pending deletion requests. See `PrivateDeletionRequest`.
    public private(set) var myDeletionRequests: [PrivateDeletionRequest] = []

    /// Every pending deletion request, oldest first. Developer only.
    public private(set) var pendingDeletionRequests: [PrivateDeletionRequest] = []

    public private(set) var isLoading = false
    public var error: FeedbackError?

    private let container: FeedbackContainer

    private var database: CKDatabase { container.database }

    /// Bumped by `reset()`. Every asynchronous operation captures it before its first `await` and
    /// drops its result if it changed meanwhile - otherwise a load started for the previous iCloud
    /// account could finish after an account switch and put that account's private reports back on
    /// screen for the new one.
    private var generation = 0

    public init(container: FeedbackContainer) {

        self.container = container
    }

    /// Clears everything derived from the current identity and invalidates operations still in flight.
    func reset() {

        generation += 1
        isLoading = false
        myReports = []
        allReports = []
        myDeletionRequests = []
        pendingDeletionRequests = []
        error = nil
    }

    /// Whether the signed-in user has asked for this report to be deleted and the developer has not
    /// processed it yet.
    public func isDeletionPending(_ report: PrivateReport) -> Bool {

        PrivateDeletionPolicy.isPending(reportName: report.id.recordName,
                                        reportCreator: report.creatorID,
                                        in: myDeletionRequests + pendingDeletionRequests)
    }

    // MARK: - Reading

    /// Loads the signed-in user's own reports, every page.
    public func loadMine() async {

        guard let me = container.currentUserRecordID else {

            myReports = []
            return
        }

        // By CloudKit's own creator reference: the `creatorID` field is written by the client and proves
        // nothing.
        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: me), action: .none)
        let scope = container.configuration.appScope
        let predicate = scope.predicate(NSPredicate(format: "creatorUserRecordID == %@", reference))
        let started = generation

        if let loaded = await loadAll(matching: predicate), started == generation { myReports = loaded.filter { scope.includes($0.appID) } }

        await loadMyDeletionRequests()
    }

    /// Loads the signed-in user's own pending deletion requests. A schema without the record type has
    /// none.
    public func loadMyDeletionRequests() async {

        guard let me = container.currentUserRecordID else { return }

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: me), action: .none)
        let started = generation

        do {

            let loaded = try await fetchDeletionRequests(matching: NSPredicate(format: "creatorUserRecordID == %@", reference))

            if started == generation { myDeletionRequests = loaded }
        }
        catch {

            if started == generation { self.error = CloudKitErrorHandler.classifyQuery(error) }
        }
    }

    /// Developer only: loads every pending deletion request.
    public func loadPendingDeletionRequests() async {

        guard container.isDeveloper else { return }

        let started = generation

        do {

            let loaded = try await fetchDeletionRequests(matching: NSPredicate(value: true))

            if started == generation { pendingDeletionRequests = loaded.sorted { $0.requestedAt < $1.requestedAt } }
        }
        catch {

            if started == generation { self.error = CloudKitErrorHandler.classifyQuery(error) }
        }
    }

    /// Every deletion request matching `predicate`, all pages. Throws, except that a missing record
    /// type (an older schema) reads as no requests.
    private func fetchDeletionRequests(matching predicate: NSPredicate) async throws -> [PrivateDeletionRequest] {

        try await Self.fetchDeletionRequests(matching: predicate, currentUserRecordID: container.currentUserRecordID, in: database)
    }

    static func fetchDeletionRequests(matching predicate: NSPredicate,
                                      currentUserRecordID me: String?,
                                      in database: CKDatabase) async throws -> [PrivateDeletionRequest] {

        let query = CKQuery(recordType: RecordType.privateReportDeletionRequest, predicate: predicate)

        var collected: [PrivateDeletionRequest] = []
        var cursor: CKQueryOperation.Cursor?
        var isFirstPage = true

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor,
                                                      desiredKeys: PrivateDeletionRequest.desiredKeys)
                }
                else {

                    page = try await database.records(matching: query,
                                                      desiredKeys: PrivateDeletionRequest.desiredKeys)
                }

                collected += page.matchResults
                    .compactMap { try? $0.1.get() }
                    .compactMap { PrivateDeletionRequest(record: $0, currentUserRecordID: me) }

                cursor = page.queryCursor
                isFirstPage = false
            }
            catch {

                if CloudKitErrorHandler.isMissingRecordType(error, isFirstPage: isFirstPage) { return [] }

                throw error
            }
        }
        while cursor != nil

        return collected
    }

    /// Developer only: loads every report, every page.
    public func loadAllReports() async {

        guard container.isDeveloper else { return }

        let started = generation

        if let loaded = await loadAll(matching: NSPredicate(value: true)), started == generation { allReports = loaded }

        await loadPendingDeletionRequests()
    }

    /// Fetches the full record including its images. The **only** place the assets are fetched.
    public func loadDetail(_ report: PrivateReport) async -> PrivateReport {

        let started = generation

        do {

            let record = try await database.record(for: report.id)

            guard started == generation else { return report }

            guard var detailed = makeReport(record) else { return report }

            if let assets = record[FieldKey.images] as? [CKAsset] {

                detailed.imageURLs = FeedbackImage.copyOut(assets)
            }

            replaceLocally(detailed)

            return detailed
        }
        catch {

            guard started == generation else { return report }

            if CloudKitErrorHandler.isRecordMissing(error) {

                removeLocally(report.id)
            }
            else {

                self.error = CloudKitErrorHandler.classify(error)
            }

            return report
        }
    }

    /// Follows the query cursor to the end, like `VoteService.loadTallies()`.
    ///
    /// Returns `nil` when nothing at all could be read, so a failed refresh leaves the previous list
    /// on screen rather than blanking it, and also when `reset()` ran during the load - a stale result
    /// is never handed back. A failure after the first page keeps what was read and surfaces the error.
    private func loadAll(matching predicate: NSPredicate) async -> [PrivateReport]? {

        let started = generation

        isLoading = true
        error = nil

        defer { if started == generation { isLoading = false } }

        let query = CKQuery(recordType: RecordType.privateReport, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: FieldKey.creationDate, ascending: false)]

        var collected: [PrivateReport] = []
        var cursor: CKQueryOperation.Cursor?
        var isFirstPage = true

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor,
                                                      desiredKeys: PrivateReport.listDesiredKeys)
                }
                else {

                    page = try await database.records(matching: query,
                                                      desiredKeys: PrivateReport.listDesiredKeys)
                }

                guard started == generation else { return nil }

                collected += page.matchResults
                    .compactMap { try? $0.1.get() }
                    .compactMap { makeReport($0) }

                cursor = page.queryCursor
                isFirstPage = false
            }
            catch {

                guard started == generation else { return nil }

                self.error = CloudKitErrorHandler.classifyQuery(error)

                if isFirstPage { return nil }

                break
            }
        }
        while cursor != nil

        return collected
    }

    // MARK: - Writing

    /// Saves a private report. Images go through the same `FeedbackImage` pipeline as public ones -
    /// downscaled, re-encoded, EXIF stripped - and are always accepted here, whatever
    /// `allowImageAttachments` says, because nobody but the developer can read them.
    public func submit(title: String,
                       body: String,
                       kind: FeedbackType,
                       imageData: [Data],
                       metadata: [String: String]) async throws -> PrivateReport {

        guard let creatorID = container.currentUserRecordID else { throw FeedbackError.notSignedIn }

        let started = generation

        let encodedMetadata = metadata.isEmpty ? "" : try RequestMetadata.encode(metadata)

        // Every field is written, unconditionally - see `FeedbackRequest` for why.
        var seeded = CKRecord(recordType: RecordType.privateReport)

        seeded[FieldKey.title] = title
        seeded[FieldKey.body] = body
        seeded[FieldKey.kind] = kind.rawValue
        seeded[FieldKey.status] = RequestStatus.open.rawValue
        seeded[FieldKey.creatorID] = creatorID
        seeded[FieldKey.replies] = [String]()
        seeded[FieldKey.payload] = encodedMetadata
        seeded[FieldKey.lastActivityAt] = Date.now

        if let appID = container.configuration.appScope.appID { seeded[FieldKey.appID] = appID }

        let environment = DeviceInfo.current()

        seeded[FieldKey.appVersion] = environment.appVersion
        seeded[FieldKey.buildNumber] = environment.buildNumber
        seeded[FieldKey.osVersion] = environment.osVersion
        seeded[FieldKey.deviceModel] = environment.deviceModel
        seeded[FieldKey.platform] = environment.platform

        if !imageData.isEmpty {

            seeded[FieldKey.images] = try FeedbackImage.prepareForUpload(imageData).map { CKAsset(fileURL: $0) }
        }

        do {

            seeded = try await database.save(seeded)
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }

        guard let saved = makeReport(seeded) else {

            throw FeedbackError.underlying(String(localized: "Could not read back the saved report."))
        }

        // Saved either way - it is the previous account's record - but only listed if that account is
        // still the one signed in.
        if started == generation { myReports.insert(saved, at: 0) }

        return saved
    }

    /// Developer reply, appended to the report's own `replies` list.
    ///
    /// Refused here for anyone not in `developerUserRecordIDs`. **That is a convenience, not
    /// authentication** - the real protection is the schema: `_creator` has READ only on
    /// `PrivateReport`, so CloudKit rejects a submitter's write however it is made.
    public func reply(to report: PrivateReport, message: String) async throws {

        guard container.isDeveloper else { throw FeedbackError.developerOnly }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        let entry = try PrivateReply(message: String(trimmed.prefix(PrivateReply.maximumMessageLength)),
                                     createdAt: .now).encoded()

        try await mutate(report) { record in

            var replies = record[FieldKey.replies] as? [String] ?? []
            replies.append(entry)

            record[FieldKey.replies] = replies
        }
    }

    /// Developer status change. Refused for non-developers here as a convenience; the `dev` role is
    /// what CloudKit enforces (see `reply(to:message:)`).
    public func setStatus(_ status: RequestStatus, on report: PrivateReport) async throws {

        guard container.isDeveloper else { throw FeedbackError.developerOnly }

        try await mutate(report) { record in

            record[FieldKey.status] = status.rawValue
        }
    }

    /// Fetch, change, save - so a write never clobbers fields this client did not load. Bumps
    /// `lastActivityAt`. A concurrent edit surfaces as an error rather than being overwritten.
    private func mutate(_ report: PrivateReport, _ change: (CKRecord) -> Void) async throws {

        let started = generation

        do {

            let record = try await database.record(for: report.id)

            // Never written by a developer, so `replies` and `status` are whatever the creator put there
            // at creation. Discard them before the first developer write makes them look trusted.
            if !PrivateReportTrust.isDeveloperModified(record,
                                                       developerUserRecordIDs: container.configuration.developerUserRecordIDs,
                                                       currentUserRecordID: container.currentUserRecordID) {

                record[FieldKey.replies] = [String]()
                record[FieldKey.status] = PrivateReportTrust.initialStatus.rawValue
            }

            change(record)
            record[FieldKey.lastActivityAt] = Date.now

            let saved = try await database.save(record)

            if started == generation, var updated = makeReport(saved) {

                updated.imageURLs = report.imageURLs
                replaceLocally(updated)
            }
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }
    }

    // MARK: - Deletion requests

    /// Asks the developer to delete one report. Asking again while one is pending is not an error.
    public func requestDeletion(of report: PrivateReport) async throws {

        try await createDeletionRequest(scope: .reports, reportNames: [report.id.recordName])
    }

    /// Asks the developer to delete every private report this user has sent. Used by delete-my-data.
    public func requestDeletionOfAll() async throws {

        try await createDeletionRequest(scope: .all, reportNames: [])
    }

    private func createDeletionRequest(scope: PrivateDeletionScope, reportNames: [String]) async throws {

        guard let me = container.currentUserRecordID else { throw FeedbackError.notSignedIn }

        let started = generation

        try await Self.saveDeletionRequest(scope: scope, reportNames: reportNames, requesterID: me, in: database)

        if started == generation { await loadMyDeletionRequests() }
    }

    /// Files a deletion request unless one of the user's own pending requests already covers it.
    ///
    /// Each request gets a fresh, CloudKit-generated record name. A predictable name such as
    /// `privdel_all_<user>` could be created first by another account - user record IDs are visible on
    /// the public board - and would then block or fake the victim's request. Duplicates are found
    /// instead by querying requests whose **CloudKit creator** is this user, which no one else can forge.
    static func saveDeletionRequest(scope: PrivateDeletionScope,
                                    reportNames: [String],
                                    requesterID: String,
                                    in database: CKDatabase) async throws {

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: requesterID), action: .none)

        let existing: [PrivateDeletionRequest]

        do {

            existing = try await fetchDeletionRequests(matching: NSPredicate(format: "creatorUserRecordID == %@", reference),
                                                       currentUserRecordID: requesterID,
                                                       in: database)
        }
        catch {

            throw CloudKitErrorHandler.classifyQuery(error)
        }

        guard !PrivateDeletionPolicy.isCovered(scope: scope, reportNames: reportNames, requesterID: requesterID, by: existing) else { return }

        let record = CKRecord(recordType: RecordType.privateReportDeletionRequest)

        record[FieldKey.scope] = scope.rawValue
        record[FieldKey.reportNames] = reportNames

        do {

            _ = try await database.save(record)
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }
    }

    /// Developer only: deletes what a request covers, then the request itself.
    ///
    /// The requester is the request's CloudKit creator, and only reports **that account created** are
    /// deleted - checked against each report's own `creatorUserRecordID`, never a client-written field.
    public func process(_ request: PrivateDeletionRequest) async throws {

        guard container.isDeveloper else { throw FeedbackError.developerOnly }

        let started = generation

        do {

            let targets: [CKRecord.ID]

            switch request.scope {

            case .all: targets = try await reportIDs(createdBy: request.requesterID)
            case .reports: targets = try await ownedReportIDs(named: request.reportNames, requesterID: request.requesterID)
            }

            try await CloudKitBatch.delete(targets, in: database)

            do {

                _ = try await database.deleteRecord(withID: request.id)
            }
            catch {

                guard CloudKitErrorHandler.isRecordMissing(error) else { throw error }
            }

            guard started == generation else { return }

            let deleted = Set(targets)

            allReports.removeAll { deleted.contains($0.id) }
            myReports.removeAll { deleted.contains($0.id) }
            pendingDeletionRequests.removeAll { $0.id == request.id }
            myDeletionRequests.removeAll { $0.id == request.id }
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }
    }

    /// Every report created by `requesterID`, by CloudKit's own creator reference. All pages.
    private func reportIDs(createdBy requesterID: String) async throws -> [CKRecord.ID] {

        guard !requesterID.isEmpty else { return [] }

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: requesterID), action: .none)
        let query = CKQuery(recordType: RecordType.privateReport,
                            predicate: NSPredicate(format: "creatorUserRecordID == %@", reference))

        var collected: [CKRecord.ID] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {

            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

            if let cursor {

                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
            }
            else {

                page = try await database.records(matching: query, desiredKeys: [])
            }

            collected.append(contentsOf: page.matchResults.map { $0.0 })

            cursor = page.queryCursor
        }
        while cursor != nil

        return collected
    }

    /// The named reports that exist and were created by `requesterID`. Only reports CloudKit confirms
    /// are missing are skipped - already deleted is the outcome wanted. Any other per-record failure is
    /// thrown, so the deletion request stays in the queue for a retry rather than being removed while a
    /// report survives.
    private func ownedReportIDs(named names: [String], requesterID: String) async throws -> [CKRecord.ID] {

        let ids = names.map { CKRecord.ID(recordName: $0) }

        guard !ids.isEmpty else { return [] }

        // Chunked: an app-scoped request names every report in that app, which can exceed CloudKit's
        // per-operation limit and would otherwise fail on every retry.
        var results: [(CKRecord.ID, Result<CKRecord, any Error>)] = []

        for chunk in ids.chunked(into: CloudKitBatch.maximumOperationSize) {

            let fetched = try await database.records(for: chunk, desiredKeys: [])

            results.append(contentsOf: fetched.map { ($0.key, $0.value) })
        }

        let me = container.currentUserRecordID

        var owners: [String: String] = [:]

        for (id, result) in results {

            let record: CKRecord

            switch result {

            case .success(let fetched):
                record = fetched

            case .failure(let error):
                if CloudKitErrorHandler.isRecordMissing(error) { continue }
                throw error
            }

            // `reportNames` is client-written and `records(for:)` fetches any type. Without this, naming
            // the requester's own public `Request` would delete it, and cascade its votes and replies.
            guard PrivateDeletionPolicy.isDeletableTarget(recordType: record.recordType) else { continue }

            guard let owner = PrivateDeletionPolicy.resolvedCreator(record.creatorUserRecordID?.recordName,
                                                                    currentUserRecordID: me) else { continue }

            owners[id.recordName] = owner
        }

        return PrivateDeletionPolicy.deletableReportNames(requested: names, owners: owners, requesterID: requesterID)
            .map { CKRecord.ID(recordName: $0) }
    }

    /// Maps a record with the developer-field trust rule applied - see `PrivateReportTrust`.
    private func makeReport(_ record: CKRecord) -> PrivateReport? {

        PrivateReport(record: record,
                      developerUserRecordIDs: container.configuration.developerUserRecordIDs,
                      currentUserRecordID: container.currentUserRecordID)
    }

    /// Swaps in a fresher copy wherever the report is listed.
    private func replaceLocally(_ updated: PrivateReport) {

        if let index = myReports.firstIndex(where: { $0.id == updated.id }) { myReports[index] = updated }
        if let index = allReports.firstIndex(where: { $0.id == updated.id }) { allReports[index] = updated }
    }

    /// Drops a report that no longer exists from both lists.
    private func removeLocally(_ id: CKRecord.ID) {

        myReports.removeAll { $0.id == id }
        allReports.removeAll { $0.id == id }
    }
}
