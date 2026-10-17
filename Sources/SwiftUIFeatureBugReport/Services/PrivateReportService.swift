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

    /// Follow-ups with their text, keyed by report record name - filled per report by `loadDetail`.
    private var threadFollowUps: [String: [PrivateFollowUp]] = [:]

    /// Developer only: every follow-up's author and time (no text), keyed by report record name, for
    /// the pending rule. Filled by `loadAllReports`.
    private var followUpActivity: [String: [PrivateFollowUp]] = [:]

    /// Reports known to be deleted this session - by this device, or found missing when fetched by ID.
    /// A lagging query index can keep returning them for a while; they are never listed again. See
    /// `PrivateReportConsistency`.
    private var tombstones: Set<String> = []

    /// Reports this device created that the query index may not return yet. Kept on the list until it
    /// does. See `PrivateReportConsistency.merging`.
    private var pendingSubmissions: [PrivateReport] = []

    /// The follow-ups known for every report: the detail's full copy where loaded, the bulk activity
    /// otherwise. Unfiltered - `PrivateThread` decides which are shown.
    public var followUpsByReport: [String: [PrivateFollowUp]] { followUpActivity.merging(threadFollowUps) { _, thread in thread } }

    /// One report's follow-ups. See `followUpsByReport`.
    public func followUps(for report: PrivateReport) -> [PrivateFollowUp] {

        threadFollowUps[report.id.recordName] ?? followUpActivity[report.id.recordName] ?? []
    }

    /// The report's conversation after its opening message - see `PrivateThread`.
    public func messages(for report: PrivateReport) -> [PrivateThreadMessage] {

        PrivateThread.messages(report: report,
                               followUps: followUps(for: report),
                               developerUserRecordIDs: container.configuration.developerUserRecordIDs)
    }

    public private(set) var isLoading = false

    /// Whether `loadMine()` has produced a list for the current identity. Private-only mode's board
    /// uses this the way the public board uses `RequestService.hasLoadedOnce`.
    public private(set) var hasLoadedMine = false
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
        hasLoadedMine = false
        myReports = []
        allReports = []
        myDeletionRequests = []
        pendingDeletionRequests = []
        threadFollowUps = [:]
        followUpActivity = [:]
        tombstones = []
        pendingSubmissions = []
        error = nil
    }

    /// Whether the signed-in user has asked for this report to be deleted and the developer has not
    /// processed it yet.
    public func isDeletionPending(_ report: PrivateReport) -> Bool {

        PrivateDeletionPolicy.isPending(reportName: report.id.recordName,
                                        reportCreator: report.creatorID,
                                        in: myDeletionRequests + pendingDeletionRequests)
    }

    /// The developer's pending figure - see `PrivateQueuePolicy` for the rule. Zero until
    /// `loadAllReports()` has run, so only meaningful for a developer.
    public func pendingCount(appFilter: AppFilter = .all) -> Int {

        PrivateQueuePolicy.pendingCount(reports: allReports,
                                        deletionRequests: pendingDeletionRequests,
                                        appFilter: appFilter,
                                        followUps: followUpsByReport,
                                        developerUserRecordIDs: container.configuration.developerUserRecordIDs)
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

        // Replaces the list - nothing from an earlier load survives except reports this device has just
        // sent and the index does not return yet, and those are checked by ID like the rest.
        if let loaded = await loadAll(matching: predicate, including: pendingSubmissions), started == generation {

            let merged = PrivateReportConsistency.merging(query: loaded.query, pending: loaded.extra)

            pendingSubmissions = merged.stillPending
            myReports = merged.reports.filter { scope.includes($0.appID) }
            hasLoadedMine = true
        }

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

        if let loaded = await loadAll(matching: NSPredicate(value: true)), started == generation { allReports = loaded.query }

        await loadPendingDeletionRequests()
        await loadFollowUpActivity()
    }

    // MARK: - Follow-ups

    /// Developer only: every follow-up's author and time, for the pending rule. A schema without the
    /// `PrivateReply` type reads as none.
    private func loadFollowUpActivity() async {

        guard container.isDeveloper else { return }

        let started = generation

        do {

            let loaded = try await fetchFollowUps(matching: NSPredicate(value: true), desiredKeys: [FieldKey.report], sorted: false)

            if started == generation { followUpActivity = Dictionary(grouping: loaded, by: \.reportName) }
        }
        catch {

            if started == generation { self.error = CloudKitErrorHandler.classifyQuery(error) }
        }
    }

    /// One report's follow-ups, with their text, oldest first.
    ///
    /// For the submitter CloudKit returns only the ones they created (`_creator` READ); for a developer,
    /// every one (`dev` READ). Either way `PrivateThread` drops any whose creator is neither the
    /// report's creator nor a developer.
    public func loadFollowUps(for report: PrivateReport) async {

        let started = generation
        let reference = CKRecord.Reference(recordID: report.id, action: .none)

        do {

            let loaded = try await fetchFollowUps(matching: NSPredicate(format: "%K == %@", FieldKey.report, reference),
                                                  desiredKeys: PrivateFollowUp.desiredKeys,
                                                  sorted: true)

            if started == generation { threadFollowUps[report.id.recordName] = loaded }
        }
        catch {

            if started == generation { self.error = CloudKitErrorHandler.classifyQuery(error) }
        }
    }

    /// Sends a follow-up on the signed-in user's own report.
    ///
    /// Refused unless `PrivateThread.acceptsFollowUp` - the report must be theirs and not `.complete`.
    /// That is a convenience: what CloudKit enforces is that the record is attributed to its creator,
    /// and `PrivateThread` shows it only on a report that creator made. The record is immutable once
    /// saved (`_creator` READ only).
    public func sendFollowUp(_ message: String, on report: PrivateReport) async throws {

        guard let me = container.currentUserRecordID else { throw FeedbackError.notSignedIn }

        guard PrivateThread.acceptsFollowUp(report: report, currentUserRecordID: me) else {

            throw FeedbackError.underlying(String(localized: "You can't reply to this report."))
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        let started = generation
        let record = CKRecord(recordType: RecordType.privateReply)

        record[FieldKey.report] = CKRecord.Reference(recordID: report.id, action: .deleteSelf)
        record[FieldKey.body] = String(trimmed.prefix(PrivateThread.maximumMessageLength))

        // The report's own app, so per-app deletion finds the follow-up with its report.
        if let appID = report.appID { record[FieldKey.appID] = appID }

        let saved: CKRecord

        do {

            saved = try await database.save(record)
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }

        guard started == generation, let followUp = PrivateFollowUp(record: saved, currentUserRecordID: me) else { return }

        threadFollowUps[report.id.recordName, default: []].append(followUp)
    }

    /// Every `PrivateReply` matching `predicate`, all pages. A missing record type reads as none.
    private func fetchFollowUps(matching predicate: NSPredicate, desiredKeys: [String], sorted: Bool) async throws -> [PrivateFollowUp] {

        let me = container.currentUserRecordID
        let query = CKQuery(recordType: RecordType.privateReply, predicate: predicate)

        if sorted { query.sortDescriptors = [NSSortDescriptor(key: FieldKey.creationDate, ascending: true)] }

        var collected: [PrivateFollowUp] = []
        var cursor: CKQueryOperation.Cursor?
        var isFirstPage = true

        repeat {

            do {

                let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor {

                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: desiredKeys)
                }
                else {

                    page = try await database.records(matching: query, desiredKeys: desiredKeys)
                }

                collected += page.matchResults
                    .compactMap { try? $0.1.get() }
                    .compactMap { PrivateFollowUp(record: $0, currentUserRecordID: me) }

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

    /// Developer only: the IDs of every `PrivateReply` created by `requesterID`, with the report each
    /// points at. A missing record type reads as none.
    private func followUpIDs(createdBy requesterID: String) async throws -> [(id: CKRecord.ID, reportName: String)] {

        guard !requesterID.isEmpty else { return [] }

        let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: requesterID), action: .none)

        return try await fetchFollowUps(matching: NSPredicate(format: "creatorUserRecordID == %@", reference),
                                        desiredKeys: [FieldKey.report],
                                        sorted: false)
            .map { (id: $0.id, reportName: $0.reportName) }
    }

    /// Fetches the full record including its images. The **only** place the image assets are fetched.
    /// File assets are not - they can be large, and are fetched one at a time by `downloadFile`.
    public func loadDetail(_ report: PrivateReport) async -> PrivateReport {

        let started = generation

        do {

            let record = try await fetchRecord(report.id, desiredKeys: PrivateReport.detailDesiredKeys)

            guard started == generation else { return report }

            guard var detailed = makeReport(record) else { return report }

            await loadFollowUps(for: detailed)

            guard started == generation else { return report }

            if let assets = record[FieldKey.images] as? [CKAsset] {

                detailed.imageURLs = FeedbackImage.copyOut(assets)
            }

            replaceLocally(detailed)

            return detailed
        }
        catch {

            guard started == generation else { return report }

            if CloudKitErrorHandler.isRecordMissing(error) {

                // Deleted - by the developer, or a processed deletion request. Gone from the lists for
                // good, whatever a lagging query says next.
                forget(report.id)
            }
            else {

                self.error = CloudKitErrorHandler.classify(error)
            }

            return report
        }
    }

    /// Whether the report is known to be deleted - its detail should close.
    public func isKnownDeleted(_ report: PrivateReport) -> Bool { tombstones.contains(report.id.recordName) }

    /// Downloads one attached file and copies it to a temporary file under its original name, so Quick
    /// Look, the share sheet and Books see the right name and type.
    ///
    /// Each call fetches only the `files` field. Throws `FileAttachmentError.missing` when the report no
    /// longer has an asset at that position.
    public func downloadFile(_ file: PrivateFile, of report: PrivateReport) async throws -> URL {

        let record: CKRecord

        do {

            record = try await fetchRecord(report.id, desiredKeys: [FieldKey.files])
        }
        catch {

            if CloudKitErrorHandler.isRecordMissing(error) {

                forget(report.id)
                throw FileAttachmentError.missing(name: file.name)
            }

            throw CloudKitErrorHandler.classify(error)
        }

        let assets = record[FieldKey.files] as? [CKAsset] ?? []

        guard file.index < assets.count, let source = assets[file.index].fileURL else {

            throw FileAttachmentError.missing(name: file.name)
        }

        return try Self.copyOut(source, named: file.name, reportName: report.id.recordName, index: file.index)
    }

    /// `CKAsset.fileURL` is only valid while the operation that produced it lives, so it is copied out
    /// at once - see `FeedbackImage.copyOut`. The name is sanitised again here: it came from the record,
    /// which its creator wrote.
    nonisolated static func copyOut(_ source: URL, named name: String, reportName: String, index: Int) throws -> URL {

        let safeReport = FileAttachmentName.sanitized(reportName, fallback: "report")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackFiles", isDirectory: true)
            .appendingPathComponent("\(safeReport)-\(index)", isDirectory: true)

        let destination = directory.appendingPathComponent(FileAttachmentName.sanitized(name))

        do {

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }

            try FileManager.default.copyItem(at: source, to: destination)
        }
        catch {

            throw FileAttachmentError.unreadable(name: name)
        }

        return destination
    }

    /// One record with only `desiredKeys`. A missing record throws CloudKit's own error.
    private func fetchRecord(_ id: CKRecord.ID, desiredKeys: [String]) async throws -> CKRecord {

        let results = try await database.records(for: [id], desiredKeys: desiredKeys)

        guard let result = results[id] else { throw CKError(.unknownItem) }

        return try result.get()
    }

    /// Follows the query cursor to the end, like `VoteService.loadTallies()`.
    ///
    /// Returns `nil` when nothing at all could be read, so a failed refresh leaves the previous list
    /// on screen rather than blanking it, and also when `reset()` ran during the load - a stale result
    /// is never handed back. A failure after the first page keeps what was read and surfaces the error.
    ///
    /// Everything the query returned - and `extra`, reports listed locally that the query may not
    /// return yet - is then checked by ID (`missingReportNames`), and what is gone is dropped.
    private func loadAll(matching predicate: NSPredicate,
                         including extra: [PrivateReport] = []) async -> (query: [PrivateReport], extra: [PrivateReport])? {

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

        let gone = await missingReportNames(Set((collected + extra).map(\.id)))

        guard started == generation else { return nil }

        tombstones.formUnion(gone)

        return (PrivateReportConsistency.pruned(collected, removing: tombstones),
                PrivateReportConsistency.pruned(extra, removing: tombstones))
    }

    /// Which of `ids` no longer exist, by fetching them by ID with no fields - not served from the
    /// query index, so it sees a deletion at once. Best effort: a failed check reports nothing gone.
    private func missingReportNames(_ ids: Set<CKRecord.ID>) async -> Set<String> {

        var gone: Set<String> = []

        for chunk in Array(ids).chunked(into: CloudKitBatch.maximumOperationSize) {

            guard let fetched = try? await database.records(for: chunk, desiredKeys: []) else { continue }

            gone.formUnion(PrivateReportConsistency.missingNames(in: fetched.map { id, result in (id, result.map { _ in () }) }))
        }

        return gone
    }

    // MARK: - Writing

    /// Saves a private report. Images go through the same `FeedbackImage` pipeline as public ones -
    /// downscaled, re-encoded, EXIF stripped - and are always accepted here, whatever
    /// `allowImageAttachments` says, because nobody but the developer can read them.
    ///
    /// `files` are checked again here against `FeedbackConfiguration.fileAttachmentRules`, whatever the
    /// form allowed, and refused outright unless `fileAttachmentsAvailable`. The three file fields are
    /// written only when there are files, so a schema without them keeps accepting file-less reports.
    public func submit(title: String,
                       body: String,
                       kind: FeedbackType,
                       imageData: [Data],
                       files: [PendingFileAttachment] = [],
                       metadata: [String: String]) async throws -> PrivateReport {

        guard let creatorID = container.currentUserRecordID else { throw FeedbackError.notSignedIn }

        if !files.isEmpty {

            let configuration = container.configuration

            guard configuration.fileAttachmentsAvailable else { throw FileAttachmentError.notAllowed }

            if let invalid = configuration.fileAttachmentRules.validate(files.map { (name: $0.name, byteCount: $0.byteCount) }) {

                throw invalid
            }
        }

        // A temporary copy that has gone would upload as nothing, or fail the whole save.
        if let unavailable = PrivateReportSubmissionCheck.firstUnavailable(files) {

            throw FileAttachmentError.unreadable(name: unavailable.name)
        }

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

        if !files.isEmpty {

            seeded[FieldKey.files] = files.map { CKAsset(fileURL: $0.url) }
            seeded[FieldKey.fileNames] = files.map { FileAttachmentName.sanitized($0.name) }
            seeded[FieldKey.fileSizes] = files.map { NSNumber(value: Int64($0.byteCount)) }
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
        // still the one signed in. Kept as pending until the query index returns it.
        if started == generation {

            myReports.insert(saved, at: 0)
            pendingSubmissions.append(saved)
        }

        // Never "sent" with a file silently missing. The report itself is saved and listed, so the
        // error says which file did not make it rather than inviting a duplicate.
        if let missing = PrivateReportSubmissionCheck.missingFile(sent: files.map(\.name), saved: saved.files) {

            throw FileAttachmentError.missing(name: missing)
        }

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

    // MARK: - Removing attachments

    /// How many times `removeAttachment` refetches and tries again after losing a save race.
    static let attachmentRemovalRetries = 2

    /// Developer only: removes one file or image from a report, to save storage. The report, its
    /// replies, status and follow-ups are kept.
    ///
    /// Only the attachment fields are fetched, and only they are saved: CloudKit sends a record's
    /// changed keys, so `replies` and `status` are neither read nor written - unless the report has
    /// never been written by a developer, when they are reset exactly as `mutate` does. This save makes
    /// the developer the last modifier, which would otherwise turn creator-supplied "replies" into
    /// trusted ones (see `PrivateReportTrust`).
    ///
    /// Saved with `.ifServerRecordUnchanged`, never `.changedKeys`: a position means nothing once the
    /// list has changed, so a concurrent save makes this refetch, check that the same attachment is
    /// still at that position, and try again (`attachmentRemovalRetries` times). `lastActivityAt` is
    /// left alone - a removal is not conversation activity.
    ///
    /// - Returns: `report` without the attachment, also swapped into the local lists.
    @discardableResult
    public func removeAttachment(_ attachment: PrivateAttachment, from report: PrivateReport) async throws -> PrivateReport {

        guard container.isDeveloper else { throw FeedbackError.developerOnly }

        let started = generation

        let keys: [String]

        switch attachment {

        case .file: keys = [FieldKey.files, FieldKey.fileNames, FieldKey.fileSizes]
        case .image: keys = [FieldKey.images]
        }

        var attempt = 0

        while true {

            do {

                // Fetches the assets that stay, too - a list field can only be saved whole.
                let record = try await fetchRecord(report.id, desiredKeys: keys)

                let resetsUntrustedFields = !PrivateReportTrust.isDeveloperModified(record,
                                                                                    developerUserRecordIDs: container.configuration.developerUserRecordIDs,
                                                                                    currentUserRecordID: container.currentUserRecordID)

                if resetsUntrustedFields {

                    record[FieldKey.replies] = [String]()
                    record[FieldKey.status] = PrivateReportTrust.initialStatus.rawValue
                }

                var updated = report
                var removedImageURL: URL?

                switch attachment {

                case .file(let file):
                    let assets = record[FieldKey.files] as? [CKAsset] ?? []
                    let names = record[FieldKey.fileNames] as? [String] ?? []
                    let sizes = (record[FieldKey.fileSizes] as? [NSNumber])?.map(\.int64Value) ?? []

                    let (keptAssets, keptNames, keptSizes) = try ParallelLists.removing(at: file.index, from: assets, names, sizes)

                    guard ParallelLists.matches(file, names: names, sizes: sizes) else { throw AttachmentRemovalError.changed }

                    // Cleared rather than left as empty lists once the last file goes.
                    let assetsValue: [CKAsset]? = keptAssets.isEmpty ? nil : keptAssets
                    let namesValue: [String]? = keptNames.isEmpty ? nil : keptNames
                    let sizesValue: [NSNumber]? = keptSizes.isEmpty ? nil : keptSizes.map { NSNumber(value: $0) }

                    record[FieldKey.files] = assetsValue
                    record[FieldKey.fileNames] = namesValue
                    record[FieldKey.fileSizes] = sizesValue

                    updated.files = PrivateFile.list(names: keptNames, sizes: keptSizes, assetCount: keptAssets.count)

                case .image(let index, let count):
                    let assets = record[FieldKey.images] as? [CKAsset] ?? []
                    let kept = try ParallelLists.removing(at: index, from: assets, expectedCount: count)

                    // Only after the count check: the local copies match the record one for one.
                    guard index < updated.imageURLs.count else { throw AttachmentRemovalError.changed }

                    let imagesValue: [CKAsset]? = kept.isEmpty ? nil : kept

                    record[FieldKey.images] = imagesValue

                    removedImageURL = updated.imageURLs.remove(at: index)
                }

                try await saveIfUnchanged(record)

                // The local copy of a removed image is no longer shown anywhere.
                if let removedImageURL { try? FileManager.default.removeItem(at: removedImageURL) }

                if resetsUntrustedFields {

                    updated.replies = []
                    updated.status = PrivateReportTrust.initialStatus
                }

                if started == generation { patchAttachmentsLocally(updated, resetsUntrustedFields: resetsUntrustedFields) }

                return updated
            }
            catch let refusal as AttachmentRemovalError {

                throw refusal
            }
            catch {

                if CloudKitErrorHandler.isServerRecordChanged(error), attempt < Self.attachmentRemovalRetries {

                    attempt += 1
                    continue
                }

                throw CloudKitErrorHandler.classify(error)
            }
        }
    }

    /// Saves one record with `.ifServerRecordUnchanged`, surfacing its own per-record error.
    private func saveIfUnchanged(_ record: CKRecord) async throws {

        let results = try await database.modifyRecords(saving: [record],
                                                       deleting: [],
                                                       savePolicy: .ifServerRecordUnchanged,
                                                       atomically: true)

        guard let result = results.saveResults[record.recordID] else { throw CKError(.unknownItem) }

        _ = try result.get()
    }

    /// Updates only the attachments (and, after a trust reset, `replies`/`status`) of the listed copies,
    /// keeping whatever else they hold - they may be fresher than the detail's copy.
    private func patchAttachmentsLocally(_ updated: PrivateReport, resetsUntrustedFields: Bool) {

        func patch(_ list: inout [PrivateReport]) {

            guard let index = list.firstIndex(where: { $0.id == updated.id }) else { return }

            list[index].files = updated.files
            list[index].imageURLs = updated.imageURLs

            if resetsUntrustedFields {

                list[index].replies = []
                list[index].status = PrivateReportTrust.initialStatus
            }
        }

        patch(&myReports)
        patch(&allReports)
    }

    /// Fetch, change, save - so a write never clobbers fields this client did not load. Bumps
    /// `lastActivityAt`. A concurrent edit surfaces as an error rather than being overwritten.
    private func mutate(_ report: PrivateReport, _ change: (CKRecord) -> Void) async throws {

        let started = generation

        do {

            // Everything but the assets: the save sends changed keys only, so leaving them out loses
            // nothing, and a reply no longer downloads every attached file first.
            let record = try await fetchRecord(report.id, desiredKeys: PrivateReport.listDesiredKeys)

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

            // The requester's follow-ups go with the reports: `.deleteSelf` cascades them, and they are
            // deleted explicitly too so nothing depends on the cascade. An `.all` request takes every
            // follow-up they created, including any pointing at reports that are not theirs.
            let targetNames = Set(targets.map(\.recordName))
            let followUps = try await followUpIDs(createdBy: request.requesterID)
                .filter { request.scope == .all || targetNames.contains($0.reportName) }
                .map { $0.id }

            try await CloudKitBatch.delete(followUps, in: database)
            try await CloudKitBatch.delete(targets, in: database)

            do {

                _ = try await database.deleteRecord(withID: request.id)
            }
            catch {

                guard CloudKitErrorHandler.isRecordMissing(error) else { throw error }
            }

            guard started == generation else { return }

            targets.forEach { forget($0) }
            targetNames.forEach { threadFollowUps[$0] = nil; followUpActivity[$0] = nil }
            pendingDeletionRequests.removeAll { $0.id == request.id }
            myDeletionRequests.removeAll { $0.id == request.id }
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }
    }

    // MARK: - Deleting a report

    /// Developer only: permanently deletes one private report - its images, files and developer
    /// replies with it - and every follow-up in its conversation, for the sender and the developer
    /// alike. Refused here for non-developers as a convenience; the `dev` role is what lets CloudKit
    /// delete another person's records.
    ///
    /// The follow-ups are queried and deleted first, explicitly: `.deleteSelf` would cascade them, but
    /// nothing here depends on that. Records that are already gone count as deleted. If anything else
    /// fails the error is thrown and the report stays listed, so the developer can try again.
    ///
    /// Afterwards, best effort: pending deletion requests from the sender that named only this report
    /// are removed, being fulfilled (`.all` requests are kept - see
    /// `PrivateReportDeletion.fulfilledRequests`), and the local image and file copies are deleted.
    public func deleteReport(_ report: PrivateReport) async throws {

        guard container.isDeveloper else { throw FeedbackError.developerOnly }

        let started = generation
        let reportName = report.id.recordName

        do {

            let reference = CKRecord.Reference(recordID: report.id, action: .none)
            let followUps = try await fetchFollowUps(matching: NSPredicate(format: "%K == %@", FieldKey.report, reference),
                                                     desiredKeys: [FieldKey.report],
                                                     sorted: false)

            let followUpIDs = PrivateReportDeletion.followUpIDs(followUps.map { (id: $0.id, reportName: $0.reportName) },
                                                                reportName: reportName)

            try await CloudKitBatch.delete(followUpIDs, in: database)
            try await CloudKitBatch.delete([report.id], in: database)
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }

        // The report is gone. Nothing below may fail the deletion.
        let fulfilled = PrivateReportDeletion.fulfilledRequests(pendingDeletionRequests + myDeletionRequests,
                                                                reportName: reportName,
                                                                reportCreator: report.creatorID)

        var removedRequests: Set<CKRecord.ID> = []

        for request in fulfilled where !removedRequests.contains(request.id) {

            do {

                _ = try await database.deleteRecord(withID: request.id)
                removedRequests.insert(request.id)
            }
            catch {

                // Left in the queue otherwise: processing it later finds the report gone and removes it.
                if CloudKitErrorHandler.isRecordMissing(error) { removedRequests.insert(request.id) }
            }
        }

        let imageURLs = Set(([report] + myReports + allReports).filter { $0.id == report.id }.flatMap(\.imageURLs))

        Self.removeCachedCopies(reportName: reportName, imageURLs: Array(imageURLs))

        guard started == generation else { return }

        forget(report.id)
        threadFollowUps[reportName] = nil
        followUpActivity[reportName] = nil
        pendingDeletionRequests.removeAll { removedRequests.contains($0.id) }
        myDeletionRequests.removeAll { removedRequests.contains($0.id) }
    }

    /// Deletes the report's local copies: the images `loadDetail` copied out, and the files
    /// `downloadFile` saved under `FeedbackFiles`. Only paths this service creates are touched.
    nonisolated static func removeCachedCopies(reportName: String, imageURLs: [URL]) {

        let fileManager = FileManager.default

        for url in imageURLs where PrivateReportDeletion.isCachedImageCopy(url) {

            try? fileManager.removeItem(at: url)
        }

        let filesDirectory = fileManager.temporaryDirectory.appendingPathComponent("FeedbackFiles", isDirectory: true)

        guard let entries = try? fileManager.contentsOfDirectory(atPath: filesDirectory.path) else { return }

        for entry in entries where PrivateReportDeletion.isCachedFileDirectory(entry, reportName: reportName) {

            try? fileManager.removeItem(at: filesDirectory.appendingPathComponent(entry, isDirectory: true))
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

    /// Drops a report that no longer exists from both lists, and keeps it off them for the session.
    private func forget(_ id: CKRecord.ID) {

        tombstones.insert(id.recordName)
        pendingSubmissions.removeAll { $0.id == id }
        myReports.removeAll { $0.id == id }
        allReports.removeAll { $0.id == id }
    }
}
