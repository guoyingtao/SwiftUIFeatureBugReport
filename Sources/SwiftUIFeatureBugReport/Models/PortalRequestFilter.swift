//
//  PortalRequestFilter.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import Foundation

/// The developer portal's filters over public requests: app, version, search and queue.
///
/// Pulled out of `DeveloperPortalView` so the rules can be tested; the view owns the state and
/// builds one of these per render.
struct PortalRequestFilter {

    var appFilter: AppFilter
    var versionFilter: String?
    var searchText: String
    var queue: PortalQueue

    /// Whether `request` belongs in the current queue. `reportCount` is only asked on the Reported queue.
    func includes(_ request: FeedbackRequest, reportCount: (CKRecord.ID) -> Int) -> Bool {

        // Every app in a shared container, so a developer can triage them all from one build.
        guard appFilter.matches(request.appID) else { return false }

        guard versionFilter == nil || request.environment.appVersion == versionFilter else { return false }

        // Client-side over the already-loaded board - no extra query, and it can match the
        // author ID, which is what you have when a deletion request arrives by email.
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !needle.isEmpty {

            let haystack = [request.title, request.body, request.creatorID].joined(separator: " ").lowercased()

            guard haystack.contains(needle) else { return false }
        }

        switch queue {

        // Named for exactly what it filters on, so the tab and the behaviour cannot drift apart.
        case .open: return request.status == .open && request.moderation != .hidden
        case .reported: return reportCount(request.id) > 0
        case .images: return request.imageState == .pending
        case .all: return true
        }
    }

    /// The version picker's choices: versions of the selected app only, newest first, blanks dropped.
    /// BeeDay 2.1 and BeeTunes 2.1 are unrelated builds.
    static func availableVersions(in requests: [FeedbackRequest], appFilter: AppFilter) -> [String] {

        Array(Set(requests.filter { appFilter.matches($0.appID) }.map(\.environment.appVersion)))
            .filter { !$0.isEmpty }
            .sorted(by: >)
    }
}
