//
//  AppDataScopingTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("My data app scoping")
struct AppDataScopingTests {

    private let parents = ["r-day": "BeeDay", "r-tunes": "BeeTunes"]

    private let records = [
        AppScopedRecord(name: "req-day", ownAppID: "BeeDay"),
        AppScopedRecord(name: "req-tunes", ownAppID: "BeeTunes"),
        AppScopedRecord(name: "req-legacy"),
        AppScopedRecord(name: "comment-day", parentRequestName: "r-day"),
        AppScopedRecord(name: "comment-tunes", parentRequestName: "r-tunes"),
        AppScopedRecord(name: "comment-orphan", parentRequestName: "r-gone")
    ]

    private func names(_ scope: AppScope) -> [String] {

        AppDataScoping.filter(records, parentAppIDs: parents, scope: scope).map(\.name)
    }

    @Test("No appID keeps everything, the account-wide behaviour")
    func unscopedKeepsAll() {

        #expect(names(.unscoped) == records.map(\.name))
        #expect(AppDataScoping.needsParentLookup(.unscoped) == false)
    }

    @Test("A set appID keeps its own records and children of its requests")
    func scopedKeepsOwnApp() {

        #expect(names(AppScope(appID: "BeeDay")) == ["req-day", "comment-day"])
        #expect(AppDataScoping.needsParentLookup(AppScope(appID: "BeeDay")))
    }

    @Test("Unscoped legacy records and orphans count only with includesUnscopedRecords")
    func legacyIncludedOnRequest() {

        #expect(names(AppScope(appID: "BeeDay", includesUnscopedRecords: true))
                == ["req-day", "req-legacy", "comment-day", "comment-orphan"])
    }

    @Test("A record's own appID wins over its parent's")
    func ownAppIDWins() {

        let record = AppScopedRecord(name: "a", ownAppID: " BeeDay ", parentRequestName: "r-tunes")

        #expect(AppDataScoping.effectiveAppID(of: record, parentAppIDs: parents) == "BeeDay")
        #expect(AppDataScoping.effectiveAppID(of: AppScopedRecord(name: "b", ownAppID: ""), parentAppIDs: parents) == nil)
    }

    @Test("Only records without their own appID need a parent lookup")
    func parentsToResolve() {

        #expect(AppDataScoping.parentNamesToResolve(records) == ["r-day", "r-tunes", "r-gone"])
    }

    private func request(_ name: String, _ scope: PrivateDeletionScope, _ reports: [String], by requester: String = "me") -> PrivateDeletionRequest {

        PrivateDeletionRequest(id: CKRecord.ID(recordName: name), scope: scope, reportNames: reports, requesterID: requester)
    }

    @Test("A submitter's request is .all account-wide, named reports per app, nothing when empty")
    func submitterRequest() {

        #expect(AppDataScoping.deletionRequest(scope: .unscoped, scopedReportNames: ["p1"])?.scope == .all)

        let scoped = AppDataScoping.deletionRequest(scope: AppScope(appID: "BeeDay"), scopedReportNames: ["p2", "p1"])

        #expect(scoped?.scope == .reports)
        #expect(scoped?.reportNames == ["p1", "p2"])
        #expect(AppDataScoping.deletionRequest(scope: AppScope(appID: "BeeDay"), scopedReportNames: []) == nil)
    }

    @Test("Pending deletion per app needs .all or one of this app's reports")
    func pendingPerApp() {

        let pending = [request("d1", .reports, ["other-app-report"])]
        let scope = AppScope(appID: "BeeDay")

        #expect(AppDataScoping.hasPendingDeletion(pending, requesterID: "me", scopedReportNames: ["p1"], scope: .unscoped))
        #expect(AppDataScoping.hasPendingDeletion(pending, requesterID: "me", scopedReportNames: ["p1"], scope: scope) == false)
        #expect(AppDataScoping.hasPendingDeletion([request("d2", .reports, ["p1"])], requesterID: "me", scopedReportNames: ["p1"], scope: scope))
        #expect(AppDataScoping.hasPendingDeletion([request("d3", .all, [])], requesterID: "me", scopedReportNames: [], scope: scope))
        #expect(AppDataScoping.hasPendingDeletion([request("d4", .all, [], by: "else")], requesterID: "me", scopedReportNames: [], scope: scope) == false)
    }

    @Test("Per app a developer removes only deletion requests fully covered by what was deleted")
    func fulfilledPerApp() {

        let pending = [request("all", .all, []), request("mine", .reports, ["p1"]), request("mixed", .reports, ["p1", "x9"])]

        #expect(AppDataScoping.fulfilledDeletionRequests(pending, deletedReportNames: ["p1"], scope: .unscoped).count == 3)
        #expect(AppDataScoping.fulfilledDeletionRequests(pending, deletedReportNames: ["p1"], scope: AppScope(appID: "BeeDay"))
                    .map(\.id.recordName) == ["mine"])
    }
}
