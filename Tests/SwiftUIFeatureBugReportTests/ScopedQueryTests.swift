//
//  ScopedQueryTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

/// The predicates the services send, built without a container. Narrowing by `appID` happens on the
/// server only where CloudKit can express it; the client-side `includes(_:)` is covered in AppScopeTests.
@Suite("Scoped query predicates")
struct ScopedQueryTests {

    private let beeDay = AppScope(appID: "BeeDay")
    private let beeDayWithLegacy = AppScope(appID: "BeeDay", includesUnscopedRecords: true)

    private func fields(app: String?, moderation: ModerationState) -> [String: Any] {

        var fields: [String: Any] = [FieldKey.moderation: moderation.rawValue]

        if let app { fields[FieldKey.appID] = app }

        return fields
    }

    @Test("Developers read every request in the container, hidden ones and other apps' included")
    func developerBoardReadsEverything() {

        let everything = NSPredicate(value: true).predicateFormat

        #expect(RequestService.boardPredicate(isDeveloper: true, scope: .unscoped).predicateFormat == everything)
        #expect(RequestService.boardPredicate(isDeveloper: true, scope: beeDay).predicateFormat == everything)
    }

    @Test("Users never receive hidden requests, and a scoped board asks only for its app")
    func userBoardIsScoped() {

        let scoped = RequestService.boardPredicate(isDeveloper: false, scope: beeDay)

        #expect(scoped.evaluate(with: fields(app: "BeeDay", moderation: .visible)))
        #expect(scoped.evaluate(with: fields(app: "BeeDay", moderation: .approved)))
        #expect(scoped.evaluate(with: fields(app: "BeeDay", moderation: .hidden)) == false)
        #expect(scoped.evaluate(with: fields(app: "BeeTunes", moderation: .visible)) == false)

        let unscoped = RequestService.boardPredicate(isDeveloper: false, scope: .unscoped)

        #expect(unscoped.evaluate(with: fields(app: "BeeTunes", moderation: .visible)))
        #expect(unscoped.evaluate(with: fields(app: nil, moderation: .hidden)) == false)
    }

    /// CloudKit cannot match a missing field, so including legacy records leaves the app to the client.
    @Test("Including unscoped records leaves the board query unnarrowed by app")
    func legacyBoardIsNotNarrowed() {

        let predicate = RequestService.boardPredicate(isDeveloper: false, scope: beeDayWithLegacy)

        #expect(predicate.predicateFormat.contains(FieldKey.appID) == false)
        #expect(predicate.evaluate(with: fields(app: "BeeTunes", moderation: .visible)))
        #expect(predicate.evaluate(with: fields(app: nil, moderation: .hidden)) == false)
    }

    @Test("Search keeps the full-text form and adds the app only when scoped")
    func searchPredicate() {

        let unscoped = RequestService.searchPredicate(for: "dark mode", scope: .unscoped)

        #expect(unscoped.predicateFormat == NSPredicate(format: "self CONTAINS %@", "dark mode").predicateFormat)

        let scoped = RequestService.searchPredicate(for: "dark mode", scope: beeDay)

        #expect(scoped is NSCompoundPredicate)
        #expect(scoped.predicateFormat.contains("dark mode"))
        #expect(scoped.predicateFormat.contains("\(FieldKey.appID) == \"BeeDay\""))

        #expect(RequestService.searchPredicate(for: "dark mode", scope: beeDayWithLegacy).predicateFormat == unscoped.predicateFormat)
    }

    @Test("My private reports are found by CloudKit's creator reference, narrowed to this app")
    func myReportsPredicate() throws {

        let unscoped = PrivateReportService.myReportsPredicate(creator: "_me", scope: .unscoped)
        let comparison = try #require(unscoped as? NSComparisonPredicate)

        #expect(comparison.leftExpression.keyPath == "creatorUserRecordID")

        let reference = try #require(comparison.rightExpression.constantValue as? CKRecord.Reference)

        #expect(reference.recordID.recordName == "_me")

        let scoped = try #require(PrivateReportService.myReportsPredicate(creator: "_me", scope: beeDay) as? NSCompoundPredicate)

        #expect(scoped.compoundPredicateType == .and)
        #expect(scoped.predicateFormat.contains("\(FieldKey.appID) == \"BeeDay\""))

        #expect(PrivateReportService.myReportsPredicate(creator: "_me", scope: beeDayWithLegacy) is NSComparisonPredicate)
    }
}
