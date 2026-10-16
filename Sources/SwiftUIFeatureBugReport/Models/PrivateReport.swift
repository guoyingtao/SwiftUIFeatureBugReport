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
    public let environment: DeviceEnvironment
    public var replies: [PrivateReply]
    public var lastActivityAt: Date
    public let createdAt: Date

    /// Developer-supplied metadata from `FeedbackPrefill`, decoded. Empty when none was sent.
    public let metadata: [String: String]

    /// Populated only by `PrivateReportService.loadDetail(_:)`, the one place that fetches the assets.
    public var imageURLs: [URL] = []

    public init?(record: CKRecord) {

        guard record.recordType == RecordType.privateReport else { return nil }

        self.id = record.recordID
        self.title = record[FieldKey.title] as? String ?? ""
        self.body = record[FieldKey.body] as? String ?? ""
        self.kind = FeedbackType(rawValue: record[FieldKey.kind] as? String ?? "") ?? .bug
        self.status = RequestStatus(rawValue: record[FieldKey.status] as? String ?? "") ?? .open
        self.creatorID = record[FieldKey.creatorID] as? String ?? ""
        self.replies = PrivateReply.decode(record[FieldKey.replies] as? [String] ?? [])
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

        self.environment = DeviceEnvironment(
            appVersion: record[FieldKey.appVersion] as? String ?? "",
            buildNumber: record[FieldKey.buildNumber] as? String ?? "",
            osVersion: record[FieldKey.osVersion] as? String ?? "",
            deviceModel: record[FieldKey.deviceModel] as? String ?? "",
            platform: record[FieldKey.platform] as? String ?? ""
        )
    }

    /// The keys a list query asks for - everything except `images`.
    static var listDesiredKeys: [String] {

        [
            FieldKey.title, FieldKey.body, FieldKey.kind, FieldKey.status, FieldKey.creatorID,
            FieldKey.replies, FieldKey.lastActivityAt, FieldKey.payload,
            FieldKey.appVersion, FieldKey.buildNumber, FieldKey.osVersion,
            FieldKey.deviceModel, FieldKey.platform
        ]
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
