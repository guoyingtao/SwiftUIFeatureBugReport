//
//  PrivateReport.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// A submission only its creator and the developer can read.
///
/// The `PrivateReport` record type grants READ, WRITE to `_creator`, CREATE to `_icloud` and READ,
/// WRITE to `dev` - and **nothing** to `_world`, the same grant as `RequestMetadata`. That is enforced
/// by CloudKit, not by this package's UI.
///
/// Developer replies live **on the report itself** (`replies`), not in a record type of their own. A
/// reply record would be created by the developer, so `_creator: READ` would let the *developer* read
/// it but not the person it answers. Storing replies on the report, which the submitter created, is
/// the only arrangement in which both sides can read them without granting `_world`.
public struct PrivateReport: Identifiable, Sendable, Hashable {

    public let id: CKRecord.ID
    public var title: String
    public var body: String
    public var kind: FeedbackType
    public var status: RequestStatus
    public let creatorID: String

    /// The app the report was sent from, or `nil` for an unscoped one - see `AppScope`.
    public let appID: String?
    public let environment: DeviceEnvironment
    public var replies: [PrivateReply]
    public var lastActivityAt: Date
    public let createdAt: Date

    /// Developer-supplied metadata from `FeedbackPrefill`, decoded. Empty when none was sent.
    public let metadata: [String: String]

    /// Populated only by `PrivateReportService.loadDetail(_:)`, the one place that fetches the assets.
    public var imageURLs: [URL] = []

    /// Attached files, by name and size. Their bytes are fetched only when one is opened - see
    /// `PrivateReportService.downloadFile(_:of:)`.
    public var files: [PrivateFile] = []

    /// Memberwise, for tests.
    init(id: CKRecord.ID,
         title: String = "",
         body: String = "",
         kind: FeedbackType = .bug,
         status: RequestStatus = .open,
         creatorID: String = "",
         appID: String? = nil,
         replies: [PrivateReply] = [],
         files: [PrivateFile] = [],
         createdAt: Date = Date()) {

        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.status = status
        self.creatorID = creatorID
        self.appID = AppScope.normalized(appID)
        self.environment = DeviceEnvironment(appVersion: "", buildNumber: "", osVersion: "", deviceModel: "", platform: "")
        self.replies = replies
        self.files = files
        self.lastActivityAt = createdAt
        self.createdAt = createdAt
        self.metadata = [:]
    }

    /// Maps a record, trusting `replies` and `status` only if a developer wrote them - see
    /// `PrivateReportTrust`.
    public init?(record: CKRecord, developerUserRecordIDs: [String], currentUserRecordID: String?) {

        self.init(record: record,
                  trustsDeveloperFields: PrivateReportTrust.isDeveloperModified(record,
                                                                                developerUserRecordIDs: developerUserRecordIDs,
                                                                                currentUserRecordID: currentUserRecordID),
                  currentUserRecordID: currentUserRecordID)
    }

    /// - Parameter trustsDeveloperFields: When `false`, `replies` reads as empty and `status` as
    ///   `.open`, whatever the record holds.
    ///   `creatorID` always comes from CloudKit's `creatorUserRecordID`, never the client-written field.
    init?(record: CKRecord, trustsDeveloperFields: Bool, currentUserRecordID: String? = nil) {

        guard record.recordType == RecordType.privateReport else { return nil }

        self.id = record.recordID
        self.title = record[FieldKey.title] as? String ?? ""
        self.body = record[FieldKey.body] as? String ?? ""
        self.kind = FeedbackType(rawValue: record[FieldKey.kind] as? String ?? "") ?? .bug
        self.status = trustsDeveloperFields
            ? RequestStatus(rawValue: record[FieldKey.status] as? String ?? "") ?? .open
            : PrivateReportTrust.initialStatus
        // The sender is CloudKit's authenticated creator. The `creatorID` field is written by the client,
        // so it could name someone else and impersonate them in the developer queue.
        self.creatorID = PrivateDeletionPolicy.resolvedCreator(record.creatorUserRecordID?.recordName,
                                                               currentUserRecordID: currentUserRecordID) ?? ""
        self.appID = AppScope.normalized(record[FieldKey.appID] as? String)
        self.replies = trustsDeveloperFields ? PrivateReply.decode(record[FieldKey.replies] as? [String] ?? []) : []
        self.lastActivityAt = record[FieldKey.lastActivityAt] as? Date ?? record.creationDate ?? .now
        self.createdAt = record.creationDate ?? .now

        if let payload = record[FieldKey.payload] as? String,
           let data = payload.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {

            self.metadata = decoded
        }
        else {

            self.metadata = [:]
        }

        self.files = Self.files(in: record)

        self.environment = DeviceEnvironment(
            appVersion: record[FieldKey.appVersion] as? String ?? "",
            buildNumber: record[FieldKey.buildNumber] as? String ?? "",
            osVersion: record[FieldKey.osVersion] as? String ?? "",
            deviceModel: record[FieldKey.deviceModel] as? String ?? "",
            platform: record[FieldKey.platform] as? String ?? ""
        )
    }

    /// The file list of a record. When the `files` assets were fetched their count decides how many
    /// entries there are; otherwise - a list query - the names do.
    static func files(in record: CKRecord) -> [PrivateFile] {

        let names = record[FieldKey.fileNames] as? [String] ?? []
        let sizes = (record[FieldKey.fileSizes] as? [NSNumber])?.map(\.int64Value) ?? []
        let assetCount = (record[FieldKey.files] as? [CKAsset])?.count

        return PrivateFile.list(names: names, sizes: sizes, assetCount: assetCount)
    }

    /// The keys a list query asks for - everything except the `images` and `files` assets.
    ///
    /// Asking for a key the schema does not have is harmless, so an older schema without the file
    /// fields still answers.
    static var listDesiredKeys: [String] {

        [
            FieldKey.title, FieldKey.body, FieldKey.kind, FieldKey.status, FieldKey.creatorID,
            FieldKey.replies, FieldKey.lastActivityAt, FieldKey.payload,
            FieldKey.appVersion, FieldKey.buildNumber, FieldKey.osVersion,
            FieldKey.deviceModel, FieldKey.platform, FieldKey.appID,
            FieldKey.fileNames, FieldKey.fileSizes
        ]
    }

    /// The keys the detail view asks for: the list keys plus the images. Files stay out - they can be
    /// tens of megabytes and are fetched only when opened.
    static var detailDesiredKeys: [String] { listDesiredKeys + [FieldKey.images] }
}


/// Decides whether a `PrivateReport`'s developer-controlled fields - `replies` and `status` - can be
/// believed.
///
/// The creator has no WRITE on the record type, but `_icloud: CREATE` lets them choose every field's
/// **initial** value - so a crafted report could arrive with "developer replies" already in it. CloudKit
/// does record who last modified a record, and that cannot be forged: if the last modifier is a
/// configured developer, a developer wrote the current values. Otherwise the record is exactly as its
/// creator made it, and those two fields are ignored.
enum PrivateReportTrust {

    /// What `status` reads as until a developer has written to the report.
    static let initialStatus = RequestStatus.open

    static func isDeveloperModified(_ record: CKRecord,
                                                developerUserRecordIDs: [String],
                                                currentUserRecordID: String?) -> Bool {

        isTrusted(lastModifierRecordName: record.lastModifiedUserRecordID?.recordName,
                  developerUserRecordIDs: developerUserRecordIDs,
                  currentUserRecordID: currentUserRecordID)
    }

    /// `CKCurrentUserDefaultName` - what CloudKit reports when the signed-in user is the modifier - is
    /// resolved to `currentUserRecordID` first, so a developer's own edits are recognised.
    static func isTrusted(lastModifierRecordName: String?,
                                      developerUserRecordIDs: [String],
                                      currentUserRecordID: String?) -> Bool {

        guard let modifier = PrivateDeletionPolicy.resolvedCreator(lastModifierRecordName,
                                                                   currentUserRecordID: currentUserRecordID) else { return false }

        return developerUserRecordIDs.contains(modifier)
    }
}


/// One developer reply on a `PrivateReport`.
///
/// Stored as a JSON string inside the report's `replies` list, for the reason given on
/// `PrivateReport`. One string per reply keeps an unreadable entry from taking the others with it.
public struct PrivateReply: Codable, Sendable, Hashable {

    public let message: String
    public let createdAt: Date

    public init(message: String, createdAt: Date) {

        self.message = message
        self.createdAt = createdAt
    }

    /// CloudKit rejects records over 1 MB. Replies share the report with its text and metadata, so
    /// each one is kept well short of that.
    static let maximumMessageLength = 4_000

    func encoded() throws -> String {

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Skips entries that do not decode rather than failing the whole list. Sorted oldest first.
    static func decode(_ entries: [String]) -> [PrivateReply] {

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return entries
            .compactMap { entry in entry.data(using: .utf8).flatMap { try? decoder.decode(PrivateReply.self, from: $0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
