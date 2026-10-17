//
//  FileAttachmentTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SwiftUIFeatureBugReport

@Suite("Private-only mode")
struct PrivateOnlyModeTests {

    @Test("Private-only has no public board and no toggle, and always goes private")
    func only() {

        #expect(PrivateFeedbackMode.only.hasPublicBoard == false)
        #expect(PrivateFeedbackMode.only.offersPrivateReports)
        #expect(PrivateFeedbackPolicy.offersToggle(mode: .only) == false)

        for type in FeedbackType.allCases {

            #expect(PrivateFeedbackPolicy.isForced(mode: .only, type: type, hasAttachments: false))
            #expect(PrivateFeedbackPolicy.isPrivate(mode: .only, type: type, hasAttachments: false, userChoice: false))
        }

        #expect(PrivateFeedbackPolicy.forcedReason(mode: .only, type: .feature, hasAttachments: false, hasFiles: false) == .privateOnly)
    }

    @Test("Every other mode keeps the public board")
    func otherModes() {

        for mode in [PrivateFeedbackMode.disabled, .optional, .bugsAndAttachments] {

            #expect(mode.hasPublicBoard)
        }

        #expect(PrivateFeedbackMode.disabled.offersPrivateReports == false)
        #expect(PrivateFeedbackPolicy.offersToggle(mode: .optional))
        #expect(PrivateFeedbackPolicy.offersToggle(mode: .bugsAndAttachments))
    }

    @Test("Existing modes behave as before when no file is attached")
    func unchangedWithoutFiles() {

        #expect(PrivateFeedbackPolicy.isPrivate(mode: .optional, type: .bug, hasAttachments: true, userChoice: false) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .disabled, type: .bug, hasAttachments: true, userChoice: true) == false)
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .bugsAndAttachments, type: .feature, hasAttachments: false, userChoice: false) == false)
    }
}


@Suite("File attachments: mode rules")
struct FileAttachmentModeTests {

    @Test("A file forces private in optional and bugs-and-attachments modes")
    func filesForcePrivate() {

        #expect(PrivateFeedbackPolicy.isForced(mode: .optional, type: .feature, hasAttachments: false, hasFiles: true))
        #expect(PrivateFeedbackPolicy.isPrivate(mode: .optional, type: .feature, hasAttachments: false, hasFiles: true, userChoice: false))
        #expect(PrivateFeedbackPolicy.isForced(mode: .bugsAndAttachments, type: .feature, hasAttachments: false, hasFiles: true))

        #expect(PrivateFeedbackPolicy.forcedReason(mode: .optional, type: .feature, hasAttachments: false, hasFiles: true) == .files)
        #expect(PrivateFeedbackPolicy.forcedReason(mode: .bugsAndAttachments, type: .feature, hasAttachments: false, hasFiles: true) == .files)
        #expect(PrivateFeedbackPolicy.forcedReason(mode: .bugsAndAttachments, type: .bug, hasAttachments: false, hasFiles: true) == .bugsAndAttachments)
        #expect(PrivateFeedbackPolicy.forcedReason(mode: .optional, type: .feature, hasAttachments: false, hasFiles: false) == nil)
    }

    @Test("Files never make a submission private when private feedback is disabled")
    func disabledNeverPrivate() {

        #expect(PrivateFeedbackPolicy.isPrivate(mode: .disabled, type: .bug, hasAttachments: false, hasFiles: true, userChoice: true) == false)
    }

    @Test("The file picker needs both the option and private reports")
    func allowsFiles() {

        #expect(PrivateFeedbackPolicy.allowsFiles(fileAttachmentsEnabled: true, mode: .optional))
        #expect(PrivateFeedbackPolicy.allowsFiles(fileAttachmentsEnabled: true, mode: .only))
        #expect(PrivateFeedbackPolicy.allowsFiles(fileAttachmentsEnabled: true, mode: .disabled) == false)
        #expect(PrivateFeedbackPolicy.allowsFiles(fileAttachmentsEnabled: false, mode: .only) == false)
    }

    @Test("Configuration defaults: off, 20 MB, 3 files, PDF and EPUB accepted")
    func defaults() {

        let configuration = FeedbackConfiguration(containerIdentifier: "iCloud.test")

        #expect(configuration.allowFileAttachments == false)
        #expect(configuration.fileAttachmentsAvailable == false)
        #expect(configuration.maxFileAttachmentBytes == 20 * 1024 * 1024)
        #expect(configuration.maxFileAttachments == 3)
        #expect(configuration.fileAttachmentRules.accepts(.pdf))
        #expect(configuration.fileAttachmentRules.accepts(.epub))
    }

    @Test("Files are only available with private feedback on")
    func availability() {

        #expect(FeedbackConfiguration(containerIdentifier: "c", privateFeedback: .disabled, allowFileAttachments: true).fileAttachmentsAvailable == false)
        #expect(FeedbackConfiguration(containerIdentifier: "c", privateFeedback: .only, allowFileAttachments: true).fileAttachmentsAvailable)
    }
}


@Suite("File attachments: validation")
struct FileAttachmentValidationTests {

    private let rules = FileAttachmentRules(maxBytes: 1_000, maxCount: 2, allowedTypes: [.pdf, .epub])

    @Test("A file within the limits passes")
    func valid() {

        #expect(rules.validate(name: "Manual.pdf", byteCount: 500, alreadyAttached: 0) == nil)
        #expect(rules.validate(name: "Book.epub", byteCount: 1_000, alreadyAttached: 1) == nil)
    }

    @Test("Too large, empty, wrong type and too many are refused")
    func refusals() {

        #expect(rules.validate(name: "Big.pdf", byteCount: 1_001, alreadyAttached: 0) == .tooLarge(name: "Big.pdf", bytes: 1_001, limit: 1_000))
        #expect(rules.validate(name: "Empty.pdf", byteCount: 0, alreadyAttached: 0) == .empty(name: "Empty.pdf"))
        #expect(rules.validate(name: "notes.txt", byteCount: 10, alreadyAttached: 0) == .unsupportedType(name: "notes.txt"))
        #expect(rules.validate(name: "noextension", byteCount: 10, alreadyAttached: 0) == .unsupportedType(name: "noextension"))
        #expect(rules.validate(name: "Third.pdf", byteCount: 10, alreadyAttached: 2) == .tooMany(limit: 2))
    }

    @Test("The system-reported type wins over the extension")
    func reportedType() {

        #expect(rules.validate(name: "renamed.txt", byteCount: 10, contentType: .pdf, alreadyAttached: 0) == nil)
        #expect(rules.validate(name: "fake.pdf", byteCount: 10, contentType: .plainText, alreadyAttached: 0) == .unsupportedType(name: "fake.pdf"))
    }

    @Test("[.item] accepts any file")
    func anything() {

        let open = FileAttachmentRules(maxBytes: 1_000, maxCount: 3, allowedTypes: [.item])

        #expect(open.validate(name: "archive.zip", byteCount: 10, alreadyAttached: 0) == nil)
        #expect(open.validate(name: "data.json", byteCount: 10, alreadyAttached: 0) == nil)
    }

    @Test("A batch is re-checked as a whole")
    func batch() {

        #expect(rules.validate([(name: "a.pdf", byteCount: 1), (name: "b.epub", byteCount: 1)]) == nil)
        #expect(rules.validate([(name: "a.pdf", byteCount: 1), (name: "b.pdf", byteCount: 1), (name: "c.pdf", byteCount: 1)]) == .tooMany(limit: 2))
        #expect(rules.validate([(name: "a.pdf", byteCount: 5_000)]) == .tooLarge(name: "a.pdf", bytes: 5_000, limit: 1_000))
    }

    @Test("Every refusal has a message")
    func messages() {

        let errors: [FileAttachmentError] = [.tooLarge(name: "a", bytes: 2, limit: 1), .unsupportedType(name: "a"), .tooMany(limit: 3),
                                             .empty(name: "a"), .unreadable(name: "a"), .notAllowed, .missing(name: "a")]

        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test("Icons follow the type")
    func icons() {

        #expect(FileAttachmentRules.symbolName(for: .pdf) == "doc.richtext")
        #expect(FileAttachmentRules.symbolName(for: .epub) == "book.closed")
        #expect(FileAttachmentRules.symbolName(for: nil) == "doc")
    }
}


@Suite("File attachments: names and record mapping")
struct FileAttachmentMappingTests {

    @Test("Names are reduced to a safe last path component")
    func sanitising() {

        #expect(FileAttachmentName.sanitized("Book.epub") == "Book.epub")
        #expect(FileAttachmentName.sanitized("../../etc/passwd") == "passwd")
        #expect(FileAttachmentName.sanitized("C:\\Users\\me\\Report.pdf") == "Report.pdf")
        #expect(FileAttachmentName.sanitized(".hidden.pdf") == "hidden.pdf")
        #expect(FileAttachmentName.sanitized("..") == "Attachment")
        #expect(FileAttachmentName.sanitized("   ") == "Attachment")
        #expect(FileAttachmentName.sanitized("a\u{0}b.pdf") == "ab.pdf")
    }

    @Test("Long names are cut but keep their extension")
    func longNames() {

        let long = String(repeating: "x", count: 300) + ".epub"
        let cut = FileAttachmentName.sanitized(long)

        #expect(cut.count == FileAttachmentName.maximumLength)
        #expect(cut.hasSuffix(".epub"))
    }

    @Test("Names and sizes pair up with the assets, with fallbacks for gaps")
    func pairing() {

        let files = PrivateFile.list(names: ["a.pdf", "../b.epub"], sizes: [10], assetCount: 3)

        #expect(files.map(\.name) == ["a.pdf", "b.epub", "Attachment 3"])
        #expect(files.map(\.byteCount) == [10, nil, nil])
        #expect(files.map(\.index) == [0, 1, 2])

        // Without fetched assets (a list query) the names decide.
        #expect(PrivateFile.list(names: ["a.pdf"], sizes: [], assetCount: nil).count == 1)
        #expect(PrivateFile.list(names: ["a.pdf", "b.pdf"], sizes: [], assetCount: 0).isEmpty)
    }

    @Test("A record's file names and sizes map onto the report")
    func recordMapping() throws {

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "pr-files"))

        record[FieldKey.title] = "Book won't open"
        record[FieldKey.fileNames] = ["Moby Dick.epub", "receipt.pdf"]
        record[FieldKey.fileSizes] = [NSNumber(value: Int64(2_048)), NSNumber(value: Int64(512))]

        let report = try #require(PrivateReport(record: record, trustsDeveloperFields: false))

        #expect(report.files.map(\.name) == ["Moby Dick.epub", "receipt.pdf"])
        #expect(report.files.map(\.byteCount) == [2_048, 512])
        #expect(report.files.first?.contentType?.conforms(to: .epub) == true)
    }

    @Test("A record without files maps to none")
    func noFiles() throws {

        let record = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "pr-nofiles"))

        #expect(try #require(PrivateReport(record: record, trustsDeveloperFields: false)).files.isEmpty)
    }

    @Test("List and detail queries never download file assets")
    func desiredKeys() {

        #expect(PrivateReport.listDesiredKeys.contains(FieldKey.fileNames))
        #expect(PrivateReport.listDesiredKeys.contains(FieldKey.fileSizes))
        #expect(!PrivateReport.listDesiredKeys.contains(FieldKey.files))
        #expect(!PrivateReport.detailDesiredKeys.contains(FieldKey.files))
        #expect(PrivateReport.detailDesiredKeys.contains(FieldKey.images))
    }

    @Test("A downloaded file is copied under its sanitised original name")
    func copyOut() throws {

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")

        try Data("hello".utf8).write(to: source)

        defer { try? FileManager.default.removeItem(at: source) }

        let copied = try PrivateReportService.copyOut(source, named: "../Guide.pdf", reportName: "pr1", index: 0)

        #expect(copied.lastPathComponent == "Guide.pdf")
        #expect(copied.deletingLastPathComponent().lastPathComponent == "pr1-0")
        #expect(try Data(contentsOf: copied) == Data("hello".utf8))

        // A second open replaces the earlier copy rather than failing.
        _ = try PrivateReportService.copyOut(source, named: "Guide.pdf", reportName: "pr1", index: 0)
    }
}
