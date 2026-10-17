//
//  PrivateReportConsistencyTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("Private report lists against a lagging query index")
struct PrivateReportConsistencyTests {

    private func report(_ name: String, at seconds: TimeInterval = 0) -> PrivateReport {

        PrivateReport(id: CKRecord.ID(recordName: name), createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func names(_ reports: [PrivateReport]) -> [String] { reports.map(\.id.recordName) }

    @Test("A deleted report is dropped from a refresh even when the query still returns it")
    func prunesDeleted() {

        let queried = [report("a"), report("b"), report("c")]

        #expect(names(PrivateReportConsistency.pruned(queried, removing: ["b"])) == ["a", "c"])
        #expect(names(PrivateReportConsistency.pruned(queried, removing: [])) == ["a", "b", "c"])
        #expect(names(PrivateReportConsistency.pruned(queried, removing: ["x"])) == ["a", "b", "c"])
    }

    @Test("Only a confirmed missing record counts as deleted, not any failure")
    func missingNames() {

        let results: [(CKRecord.ID, Result<Void, any Error>)] = [
            (CKRecord.ID(recordName: "present"), .success(())),
            (CKRecord.ID(recordName: "gone"), .failure(CKError(.unknownItem))),
            (CKRecord.ID(recordName: "offline"), .failure(CKError(.networkFailure))),
            (CKRecord.ID(recordName: "limited"), .failure(CKError(.requestRateLimited))),
        ]

        #expect(PrivateReportConsistency.missingNames(in: results) == ["gone"])
        #expect(PrivateReportConsistency.missingNames(in: []).isEmpty)
    }

    @Test("A fresh report the index does not return yet stays listed, first, until it does")
    func mergesPending() {

        let fresh = report("new", at: 200)
        let fresher = report("newer", at: 300)
        let older = [report("old", at: 100)]

        let first = PrivateReportConsistency.merging(query: older, pending: [fresh, fresher])

        #expect(names(first.reports) == ["newer", "new", "old"])
        #expect(names(first.stillPending) == ["newer", "new"])

        // Indexed now: the query's copy wins and it is no longer pending.
        let second = PrivateReportConsistency.merging(query: [fresh] + older, pending: first.stillPending)

        #expect(names(second.reports) == ["newer", "new", "old"])
        #expect(names(second.stillPending) == ["newer"])
    }

    @Test("A refresh replaces the list - a report the query no longer returns is not kept")
    func replacesList() {

        let merged = PrivateReportConsistency.merging(query: [report("a")], pending: [])

        #expect(names(merged.reports) == ["a"])
        #expect(merged.stillPending.isEmpty)
    }
}


@Suite("Files on a submitted private report")
struct PrivateReportSubmissionCheckTests {

    private func files(_ count: Int) -> [PrivateFile] {

        (0..<count).map { PrivateFile(index: $0, name: "f\($0).pdf", byteCount: 1) }
    }

    @Test("Every file sent must be on the saved record")
    func missingFile() {

        #expect(PrivateReportSubmissionCheck.missingFile(sent: [], saved: []) == nil)
        #expect(PrivateReportSubmissionCheck.missingFile(sent: ["a.pdf", "b.epub"], saved: files(2)) == nil)
        #expect(PrivateReportSubmissionCheck.missingFile(sent: ["a.pdf", "b.epub"], saved: files(1)) == "b.epub")
        #expect(PrivateReportSubmissionCheck.missingFile(sent: ["a.pdf"], saved: []) == "a.pdf")
    }

    @Test("A saved record read back with its assets lists every file")
    func savedRecordListsFiles() throws {

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("book.epub")
        try Data("x".utf8).write(to: url)

        let record = CKRecord(recordType: RecordType.privateReport)
        record[FieldKey.files] = [CKAsset(fileURL: url)]
        record[FieldKey.fileNames] = ["book.epub"]
        record[FieldKey.fileSizes] = [NSNumber(value: Int64(1))]

        let listed = PrivateReport.files(in: record)

        #expect(listed.map(\.name) == ["book.epub"])
        #expect(PrivateReportSubmissionCheck.missingFile(sent: ["book.epub"], saved: listed) == nil)
    }

    @Test("A temporary copy that has gone is caught before upload")
    func unavailableCopy() {

        let present = PendingFileAttachment(name: "a.pdf", byteCount: 1, url: URL(fileURLWithPath: "/tmp/present/a.pdf"))
        let gone = PendingFileAttachment(name: "b.pdf", byteCount: 1, url: URL(fileURLWithPath: "/tmp/gone/b.pdf"))

        let exists: (URL) -> Bool = { $0 == present.url }

        #expect(PrivateReportSubmissionCheck.firstUnavailable([present, gone], exists: exists) == gone)
        #expect(PrivateReportSubmissionCheck.firstUnavailable([present], exists: exists) == nil)
        #expect(PrivateReportSubmissionCheck.firstUnavailable([], exists: exists) == nil)
    }

    @Test("A coordinated copy copies the file")
    func coordinatedCopy() throws {

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("in.pdf")
        let destination = directory.appendingPathComponent("out.pdf")
        try Data("pdf".utf8).write(to: source)

        try PendingFileAttachment.coordinatedCopy(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == Data("pdf".utf8))
        #expect(throws: (any Error).self) { try PendingFileAttachment.coordinatedCopy(from: directory.appendingPathComponent("missing.pdf"), to: directory.appendingPathComponent("x.pdf")) }
    }
}
