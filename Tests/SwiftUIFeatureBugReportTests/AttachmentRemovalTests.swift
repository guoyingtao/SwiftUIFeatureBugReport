//
//  AttachmentRemovalTests.swift
//  SwiftUIFeatureBugReportTests
//

import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("Removing a private report's attachment")
struct AttachmentRemovalTests {

    @Test("Removes the same position from all three lists, keeping them paired")
    func removesFromEveryList() throws {

        let (assets, names, sizes) = try ParallelLists.removing(at: 1,
                                                                from: ["a", "b", "c"],
                                                                ["a.pdf", "b.epub", "c.txt"],
                                                                [Int64(10), 20, 30])

        #expect(assets == ["a", "c"])
        #expect(names == ["a.pdf", "c.txt"])
        #expect(sizes == [10, 30])

        let files = PrivateFile.list(names: names, sizes: sizes, assetCount: assets.count)

        #expect(files.map(\.index) == [0, 1])
        #expect(files.map(\.name) == ["a.pdf", "c.txt"])
        #expect(files.map(\.byteCount) == [10, 30])
    }

    @Test("Removing the only entry leaves empty lists")
    func removesLast() throws {

        let (assets, names, sizes) = try ParallelLists.removing(at: 0, from: [1], ["only.pdf"], [Int64(5)])

        #expect(assets.isEmpty && names.isEmpty && sizes.isEmpty)
    }

    @Test("Lists of different lengths are refused")
    func mismatchedLengths() {

        #expect(throws: AttachmentRemovalError.lengthMismatch(counts: [2, 1, 2])) {

            try ParallelLists.removing(at: 0, from: [1, 2], ["a.pdf"], [Int64(1), 2])
        }

        #expect(throws: AttachmentRemovalError.lengthMismatch(counts: [2, 2, 0])) {

            try ParallelLists.removing(at: 0, from: [1, 2], ["a.pdf", "b.pdf"], [Int64]())
        }
    }

    @Test("A position outside the lists is refused", arguments: [-1, 3, 10])
    func outOfRange(index: Int) {

        #expect(throws: AttachmentRemovalError.indexOutOfRange(index: index, count: 3)) {

            try ParallelLists.removing(at: index, from: [1, 2, 3], ["a", "b", "c"], [Int64(1), 2, 3])
        }
    }

    @Test("Empty lists have nothing to remove")
    func emptyLists() {

        #expect(throws: AttachmentRemovalError.indexOutOfRange(index: 0, count: 0)) {

            try ParallelLists.removing(at: 0, from: [Int](), [String](), [Int64]())
        }
    }

    @Test("Images: removes one, refusing a list whose length changed")
    func images() throws {

        #expect(try ParallelLists.removing(at: 0, from: ["x", "y"], expectedCount: 2) == ["y"])

        #expect(throws: AttachmentRemovalError.changed) {

            try ParallelLists.removing(at: 0, from: ["x", "y", "z"], expectedCount: 2)
        }

        #expect(throws: AttachmentRemovalError.indexOutOfRange(index: 2, count: 2)) {

            try ParallelLists.removing(at: 2, from: ["x", "y"], expectedCount: 2)
        }
    }

    @Test("The file at a position must still be the one the developer saw")
    func identity() {

        let names = ["report.pdf", "../evil.epub"]
        let sizes: [Int64] = [100, -1]
        let files = PrivateFile.list(names: names, sizes: sizes, assetCount: 2)

        #expect(ParallelLists.matches(files[0], names: names, sizes: sizes))
        // Sanitised name and missing size compare the way `PrivateFile.list` shows them.
        #expect(ParallelLists.matches(files[1], names: names, sizes: sizes))

        #expect(ParallelLists.matches(files[0], names: ["other.pdf", "../evil.epub"], sizes: sizes) == false)
        #expect(ParallelLists.matches(files[0], names: names, sizes: [101, -1]) == false)
        #expect(ParallelLists.matches(files[1], names: ["report.pdf"], sizes: [100]) == false)
    }

    @Test("Only a list that changed under the view asks for a reload")
    func staleness() {

        #expect(AttachmentRemovalError.changed.isStale)
        #expect(AttachmentRemovalError.indexOutOfRange(index: 1, count: 1).isStale)
        #expect(AttachmentRemovalError.lengthMismatch(counts: [1, 2]).isStale == false)
    }

    @Test("A developer's removal leaves the report trusted, so replies and status survive")
    func trustAfterRemoval() {

        // The save makes the developer the last modifier. That is what `PrivateReportTrust` checks, so
        // trusted replies and status stay trusted, and the creator's own edits never could be.
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: "_dev",
                                             developerUserRecordIDs: ["_dev"],
                                             currentUserRecordID: "_dev"))
        #expect(PrivateReportTrust.isTrusted(lastModifierRecordName: "__defaultOwner__",
                                             developerUserRecordIDs: ["_dev"],
                                             currentUserRecordID: "_dev"))
    }
}
