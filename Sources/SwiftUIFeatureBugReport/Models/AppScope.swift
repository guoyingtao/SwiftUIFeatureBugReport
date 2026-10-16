//
//  AppScope.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// Which app's feedback a view shows, when several apps share one CloudKit container.
///
/// **A display filter, not a security boundary.** `appID` is an ordinary field written by the client,
/// and every app in the container shares the same record types and the same permissions. A user of
/// one app can read - and, for records they created, rewrite - anything another app in the container
/// can. To keep apps' data genuinely apart, give each app its own container.
public struct AppScope: Sendable, Hashable {

    /// `nil` shows every record, which is the behaviour before app scoping existed.
    public let appID: String?

    /// Whether records written without an `appID` - by a build that predates the option, or by an app
    /// that never set it - still show when `appID` is set.
    public let includesUnscopedRecords: Bool

    public init(appID: String?, includesUnscopedRecords: Bool = false) {

        self.appID = Self.normalized(appID)
        self.includesUnscopedRecords = includesUnscopedRecords
    }

    /// Everything, unfiltered.
    public static let unscoped = AppScope(appID: nil)

    /// Trims whitespace; an empty identifier means "no app", the same as `nil`.
    public static func normalized(_ appID: String?) -> String? {

        guard let trimmed = appID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }

        return trimmed
    }

    /// Whether a record carrying `recordAppID` belongs in this scope.
    public func includes(_ recordAppID: String?) -> Bool {

        guard let appID else { return true }

        guard let recordAppID = Self.normalized(recordAppID) else { return includesUnscopedRecords }

        return recordAppID == appID
    }

    /// `base` narrowed to this app on the server, where CloudKit can express it.
    ///
    /// CloudKit predicates cannot match a *missing* field, so when unscoped records are included the
    /// query stays unfiltered and `includes(_:)` does the work on the client. Callers apply
    /// `includes(_:)` to the results either way.
    func predicate(_ base: NSPredicate) -> NSPredicate {

        guard let appID, !includesUnscopedRecords else { return base }

        let scoped = NSPredicate(format: "%K == %@", FieldKey.appID, appID)

        // CloudKit rejects `TRUEPREDICATE AND ...`, so a match-everything base is replaced, not joined.
        if base.predicateFormat == NSPredicate(value: true).predicateFormat { return scoped }

        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, scoped])
    }

    /// Distinguishes subscriptions saved by different apps in the same container, which would otherwise
    /// share an ID and silently keep whichever app registered first.
    func subscriptionSuffix() -> String {

        guard let appID else { return "" }

        return "-" + appID
    }
}


/// The developer portal's app filter.
public enum AppFilter: Hashable, Sendable {

    case all
    case app(String)

    /// Records with no `appID`.
    case unscoped

    public func matches(_ recordAppID: String?) -> Bool {

        switch self {

        case .all: return true
        case .app(let appID): return AppScope.normalized(recordAppID) == appID
        case .unscoped: return AppScope.normalized(recordAppID) == nil
        }
    }

    /// The filter's choices for the records loaded: every app seen, sorted, and `.unscoped` only if
    /// some record has no app.
    public static func choices(for appIDs: [String?]) -> [AppFilter] {

        let normalized = appIDs.map(AppScope.normalized)
        let named = Set(normalized.compactMap { $0 }).sorted()

        return [.all] + named.map { .app($0) } + (normalized.contains(nil) ? [.unscoped] : [])
    }
}
