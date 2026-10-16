//
//  AppScopeTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

@Suite("App scope")
struct AppScopeTests {

    @Test("No appID shows every record, scoped or not")
    func unscopedShowsEverything() {

        #expect(AppScope.unscoped.includes(nil))
        #expect(AppScope.unscoped.includes("BeeDay"))
    }

    @Test("A set appID shows only its own records, and hides legacy ones by default")
    func scopedHidesOthers() {

        let scope = AppScope(appID: "BeeDay")

        #expect(scope.includes("BeeDay"))
        #expect(scope.includes("BeeTunes") == false)
        #expect(scope.includes(nil) == false)
        #expect(scope.includes("") == false)
    }

    @Test("includeUnscopedRecords brings legacy records back, but not other apps'")
    func includesLegacy() {

        let scope = AppScope(appID: "BeeDay", includesUnscopedRecords: true)

        #expect(scope.includes(nil))
        #expect(scope.includes("  "))
        #expect(scope.includes("BeeTunes") == false)
    }

    @Test("Blank identifiers normalise to nil")
    func normalisation() {

        #expect(AppScope(appID: "   ").appID == nil)
        #expect(AppScope(appID: " BeeDay ").appID == "BeeDay")
        #expect(FeedbackConfiguration(containerIdentifier: "iCloud.x", appID: "").appID == nil)
        #expect(FeedbackConfiguration(containerIdentifier: "iCloud.x").appScope == .unscoped)
    }

    @Test("The server predicate narrows only when CloudKit can express it")
    func predicates() {

        let base = NSPredicate(format: "%K == %@", FieldKey.recipientID, "_u")

        #expect(AppScope.unscoped.predicate(base) == base)
        #expect(AppScope(appID: "BeeDay", includesUnscopedRecords: true).predicate(base) == base)

        let scoped = AppScope(appID: "BeeDay").predicate(base)

        #expect(scoped.evaluate(with: [FieldKey.recipientID: "_u", FieldKey.appID: "BeeDay"]))
        #expect(scoped.evaluate(with: [FieldKey.recipientID: "_u", FieldKey.appID: "BeeTunes"]) == false)

        // A match-everything base is replaced, because CloudKit rejects TRUEPREDICATE inside AND.
        let everything = AppScope(appID: "BeeDay").predicate(NSPredicate(value: true))

        #expect(everything.predicateFormat == NSPredicate(format: "%K == %@", FieldKey.appID, "BeeDay").predicateFormat)
    }

    @Test("Subscriptions saved by different apps get different IDs")
    func subscriptionSuffix() {

        #expect(AppScope.unscoped.subscriptionSuffix() == "")
        #expect(AppScope(appID: "BeeDay").subscriptionSuffix() != AppScope(appID: "BeeTunes").subscriptionSuffix())
    }

    @Test("Records read their appID")
    func recordMapping() throws {

        let record = CKRecord(recordType: RecordType.request, recordID: CKRecord.ID(recordName: "r1"))

        #expect(try #require(FeedbackRequest(record: record)).appID == nil)

        record[FieldKey.appID] = "BeeDay"

        #expect(try #require(FeedbackRequest(record: record)).appID == "BeeDay")

        let report = CKRecord(recordType: RecordType.privateReport, recordID: CKRecord.ID(recordName: "p1"))

        report[FieldKey.appID] = "BeeTunes"

        #expect(try #require(PrivateReport(record: report, trustsDeveloperFields: false)).appID == "BeeTunes")
    }

    @Test("Applying a request never clears its appID")
    func applyKeepsAppID() throws {

        let record = CKRecord(recordType: RecordType.request, recordID: CKRecord.ID(recordName: "r1"))

        try #require(FeedbackRequest(record: record)).apply(to: record)

        #expect(record[FieldKey.appID] == nil)

        record[FieldKey.appID] = "BeeDay"

        try #require(FeedbackRequest(record: record)).apply(to: record)

        #expect(record[FieldKey.appID] as? String == "BeeDay")
    }
}


@Suite("Portal app filter")
struct AppFilterTests {

    @Test("Each filter matches its records")
    func matching() {

        #expect(AppFilter.all.matches(nil))
        #expect(AppFilter.all.matches("BeeDay"))
        #expect(AppFilter.app("BeeDay").matches("BeeDay"))
        #expect(AppFilter.app("BeeDay").matches("BeeReader") == false)
        #expect(AppFilter.app("BeeDay").matches(nil) == false)
        #expect(AppFilter.unscoped.matches(nil))
        #expect(AppFilter.unscoped.matches("BeeDay") == false)
    }

    @Test("Choices list every app seen, sorted, with No app only when needed")
    func choices() {

        #expect(AppFilter.choices(for: ["BeeTunes", "BeeDay", "BeeTunes"]) == [.all, .app("BeeDay"), .app("BeeTunes")])
        #expect(AppFilter.choices(for: ["BeeDay", nil]) == [.all, .app("BeeDay"), .unscoped])
        #expect(AppFilter.choices(for: []) == [.all])
    }
}
