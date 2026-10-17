//
//  PrivateQueuePolicy.swift
//  SwiftUIFeatureBugReport
//

import Foundation
import SwiftUI

/// The developer portal's top-level switch: public requests or the private reports queue.
enum PortalSegment: String, CaseIterable, Hashable {

    case requests
    case privateReports
}


/// The private queue's own filter, alongside the portal's shared app filter and search.
enum PrivateQueueFilter: String, CaseIterable, Hashable {

    /// Only what `PrivateQueuePolicy.isPending` counts - the same rule as the badge.
    case pending
    case all

    var localised: LocalizedStringKey {

        switch self {

        case .pending: return "Pending"
        case .all: return "All"
        }
    }

    var symbolName: String {

        switch self {

        case .pending: return "tray"
        case .all: return "list.bullet"
        }
    }
}


/// The rules behind the developer's private queue and its pending badge, free of CloudKit I/O and
/// SwiftUI state so they can be tested.
///
/// **Pending** means the developer still owes an action. Two kinds of item count:
///
/// 1. A private report whose conversation (`PrivateThread`) ends with the **submitter**, **unless** a
///    pending deletion request from its own creator covers it - that request is the thing to act on,
///    and counting both would count one piece of work twice. In detail:
///    - The developer spoke last (a trusted reply, or a developer's `PrivateReply`): not pending.
///    - The submitter's follow-up is the latest message: pending, unless the status is `.complete`.
///    - Nothing after the report itself: pending while the status is still `.open` (the initial
///      status - there is no separate "new"). Moving it off `.open` without replying takes it out,
///      as before follow-ups existed.
///    A report a developer never wrote to reads as `.open` with no replies (see
///    `PrivateReportTrust`), so it counts - correctly, since nobody has looked at it. Follow-ups whose
///    creator is neither the report's creator nor a developer are ignored (`PrivateThread.author`).
/// 2. Every `PrivateDeletionRequest` that exists. Processing one deletes it, so every request still
///    loaded is pending by definition.
///
/// The app filter narrows (1) only. Deletion requests carry no `appID` - one can cover every app's
/// reports - so they count under every filter.
enum PrivateQueuePolicy {

    /// Rule (1) before the deletion-request exclusion: open and unanswered.
    static func isAwaitingDeveloper(status: RequestStatus, replyCount: Int) -> Bool {

        status == .open && replyCount == 0
    }

    /// The thread rule behind (1), before the deletion-request exclusion.
    static func isAwaitingDeveloper(_ report: PrivateReport,
                                    followUps: [PrivateFollowUp],
                                    developerUserRecordIDs: [String]) -> Bool {

        let messages = PrivateThread.messages(report: report, followUps: followUps, developerUserRecordIDs: developerUserRecordIDs)

        guard let latest = messages.last else { return isAwaitingDeveloper(status: report.status, replyCount: 0) }

        guard latest.author == .submitter else { return false }

        return report.status != .complete
    }

    /// - Parameter followUps: The report's `PrivateReply` records, any order. Empty reproduces the
    ///   rule from before follow-ups existed.
    static func isPending(_ report: PrivateReport,
                          deletionRequests: [PrivateDeletionRequest],
                          followUps: [PrivateFollowUp] = [],
                          developerUserRecordIDs: [String] = []) -> Bool {

        guard isAwaitingDeveloper(report, followUps: followUps, developerUserRecordIDs: developerUserRecordIDs) else { return false }

        return !PrivateDeletionPolicy.isPending(reportName: report.id.recordName,
                                                reportCreator: report.creatorID,
                                                in: deletionRequests)
    }

    /// The badge figure: pending reports in `appFilter` plus every pending deletion request.
    ///
    /// - Parameter followUps: `PrivateReply` records keyed by report record name.
    static func pendingCount(reports: [PrivateReport],
                             deletionRequests: [PrivateDeletionRequest],
                             appFilter: AppFilter = .all,
                             followUps: [String: [PrivateFollowUp]] = [:],
                             developerUserRecordIDs: [String] = []) -> Int {

        reports.count(where: { report in

            appFilter.matches(report.appID)
                && isPending(report,
                             deletionRequests: deletionRequests,
                             followUps: followUps[report.id.recordName] ?? [],
                             developerUserRecordIDs: developerUserRecordIDs)
        })
            + deletionRequests.count
    }

    /// Case-insensitive over title, body and sender ID - the sender ID is what arrives by email with a
    /// deletion request. An empty or whitespace-only needle matches everything.
    static func matchesSearch(_ report: PrivateReport, searchText: String) -> Bool {

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !needle.isEmpty else { return true }

        return [report.title, report.body, report.creatorID].joined(separator: " ").lowercased().contains(needle)
    }

    /// The rows the private queue lists, in the order given (the service keeps newest first).
    static func queued(_ reports: [PrivateReport],
                       deletionRequests: [PrivateDeletionRequest],
                       appFilter: AppFilter,
                       filter: PrivateQueueFilter,
                       searchText: String,
                       followUps: [String: [PrivateFollowUp]] = [:],
                       developerUserRecordIDs: [String] = []) -> [PrivateReport] {

        reports.filter { report in

            guard appFilter.matches(report.appID), matchesSearch(report, searchText: searchText) else { return false }

            switch filter {

            case .pending: return isPending(report,
                                            deletionRequests: deletionRequests,
                                            followUps: followUps[report.id.recordName] ?? [],
                                            developerUserRecordIDs: developerUserRecordIDs)
            case .all: return true
            }
        }
    }
}
