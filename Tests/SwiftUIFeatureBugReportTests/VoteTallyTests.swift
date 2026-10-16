//
//  VoteTallyTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Testing

@testable import SwiftUIFeatureBugReport

/// Tallies count distinct voters, so extra `Vote` records saved by one account cannot inflate a count.
@Suite("Vote tallies")
struct VoteTallyTests {

    private let requestA = CKRecord.ID(recordName: "request-a")
    private let requestB = CKRecord.ID(recordName: "request-b")

    @Test("Several votes from one account on one request count once")
    func duplicatesCountOnce() {

        let entries = [
            VoteService.VoteEntry(request: requestA, voter: "alice"),
            VoteService.VoteEntry(request: requestA, voter: "alice"),
            VoteService.VoteEntry(request: requestA, voter: "alice")
        ]

        #expect(VoteService.distinctTallies(entries)[requestA] == 1)
    }

    @Test("Distinct voters and distinct requests are counted independently")
    func distinctVotersAndRequests() {

        let entries = [
            VoteService.VoteEntry(request: requestA, voter: "alice"),
            VoteService.VoteEntry(request: requestA, voter: "bob"),
            VoteService.VoteEntry(request: requestB, voter: "alice")
        ]

        let tallies = VoteService.distinctTallies(entries)

        #expect(tallies[requestA] == 2)
        #expect(tallies[requestB] == 1)
    }

    @Test("No votes means no tallies")
    func empty() {

        #expect(VoteService.distinctTallies([]).isEmpty)
    }
}
