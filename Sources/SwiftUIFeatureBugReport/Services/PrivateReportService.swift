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

    public private(set) var isLoading = false
    public var error: FeedbackError?

    private let container: FeedbackContainer

    private var database: CKDatabase { container.database }

    public init(container: FeedbackContainer) {

        self.container = container
    }

    func reset() {

        myReports = []
        allReports = []
        error = nil
    }

    // MARK: - Reading

    /// Loads the signed-in user's own reports, every page.
    public func loadMine() async {

        guard let me = container.currentUserRecordID else {

            myReports = []
            return
        }

        let predicate = NSPredicate(format: "%K == %@", FieldKey.creatorID, me)

        if let loaded = await loadAll(matching: predicate) { myReports = loaded }
    }

    /// Developer only: loads every report, every page.
    public func loadAllReports() async {

        guard container.isDeveloper else { return }

        if let loaded = await loadAll(matching: NSPredicate(value: true)) { allReports = loaded }
    }

    /// Fetches the full record including its images. The **only** place the assets are fetched.
    public func loadDetail(_ report: PrivateReport) async -> PrivateReport {

        do {

            let record = try await database.record(for: report.id)

            guard var detailed = PrivateReport(record: record) else { return report }

            if let assets = record[FieldKey.images] as? [CKAsset] {

                detailed.imageURLs = FeedbackImage.copyOut(assets)
            }

            replaceLocally(detailed)

            return detailed
        }
        catch {

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
    /// Returns `nil` only when nothing at all could be read, so a failed refresh leaves the previous
    /// list on screen rather than blanking it. A failure after the first page keeps what was read
    /// and surfaces the error.
    private func loadAll(matching predicate: NSPredicate) async -> [PrivateReport]? {

        isLoading = true
        error = nil

        defer { isLoading = false }

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

                collected += page.matchResults
                    .compactMap { try? $0.1.get() }
                    .compactMap { PrivateReport(record: $0) }

                cursor = page.queryCursor
                isFirstPage = false
            }
            catch {

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

        guard let saved = PrivateReport(record: seeded) else {

            throw FeedbackError.underlying(String(localized: "Could not read back the saved report."))
        }

        myReports.insert(saved, at: 0)

        return saved
    }

    /// Developer reply, appended to the report's own `replies` list.
    public func reply(to report: PrivateReport, message: String) async throws {

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

    /// Developer status change.
    public func setStatus(_ status: RequestStatus, on report: PrivateReport) async throws {

        try await mutate(report) { record in

            record[FieldKey.status] = status.rawValue
        }
    }

    /// Fetch, change, save - so a write never clobbers fields this client did not load. Bumps
    /// `lastActivityAt`. A concurrent edit surfaces as an error rather than being overwritten.
    private func mutate(_ report: PrivateReport, _ change: (CKRecord) -> Void) async throws {

        do {

            let record = try await database.record(for: report.id)

            change(record)
            record[FieldKey.lastActivityAt] = Date.now

            let saved = try await database.save(record)

            if var updated = PrivateReport(record: saved) {

                updated.imageURLs = report.imageURLs
                replaceLocally(updated)
            }
        }
        catch {

            throw CloudKitErrorHandler.classify(error)
        }
    }

    private func replaceLocally(_ updated: PrivateReport) {

        if let index = myReports.firstIndex(where: { $0.id == updated.id }) { myReports[index] = updated }
        if let index = allReports.firstIndex(where: { $0.id == updated.id }) { allReports[index] = updated }
    }

    private func removeLocally(_ id: CKRecord.ID) {

        myReports.removeAll { $0.id == id }
        allReports.removeAll { $0.id == id }
    }
}
