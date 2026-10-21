//
//  PortalFilterTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Testing

@testable import SwiftUIFeatureBugReport

private func request(_ name: String,
                     app: String? = nil,
                     version: String = "1.0",
                     title: String = "",
                     body: String = "",
                     creator: String = "_user",
                     status: RequestStatus = .open,
                     moderation: ModerationState = .visible,
                     imageState: ImageState = .none) -> FeedbackRequest {

    let record = CKRecord(recordType: RecordType.request, recordID: CKRecord.ID(recordName: name))

    record[FieldKey.appID] = app
    record[FieldKey.appVersion] = version
    record[FieldKey.title] = title
    record[FieldKey.body] = body
    record[FieldKey.creatorID] = creator
    record[FieldKey.status] = status.rawValue
    record[FieldKey.moderation] = moderation.rawValue
    record[FieldKey.imageState] = imageState.rawValue

    return FeedbackRequest(record: record)!
}

private func filter(app: AppFilter = .all,
                    version: String? = nil,
                    search: String = "",
                    queue: PortalQueue = .all) -> PortalRequestFilter {

    PortalRequestFilter(appFilter: app, versionFilter: version, searchText: search, queue: queue)
}

private func names(_ requests: [FeedbackRequest], _ filter: PortalRequestFilter,
                   reportCount: (CKRecord.ID) -> Int = { _ in 0 }) -> [String] {

    requests.filter { filter.includes($0, reportCount: reportCount) }.map(\.id.recordName)
}

@Suite("Portal request filter")
struct PortalFilterTests {

    private let board = [request("day-1", app: "BeeDay", version: "2.1"),
                         request("day-2", app: "BeeDay", version: "2.0"),
                         request("tunes-1", app: "BeeTunes", version: "2.1"),
                         request("legacy", app: nil, version: "1.0")]

    @Test("The app filter keeps only that app's requests; No app keeps only unscoped ones")
    func appFilter() {

        #expect(names(board, filter()) == ["day-1", "day-2", "tunes-1", "legacy"])
        #expect(names(board, filter(app: .app("BeeDay"))) == ["day-1", "day-2"])
        #expect(names(board, filter(app: .unscoped))  == ["legacy"])
    }

    @Test("The version filter applies within the app filter")
    func versionWithinApp() {

        #expect(names(board, filter(version: "2.1")) == ["day-1", "tunes-1"])
        #expect(names(board, filter(app: .app("BeeDay"), version: "2.1")) == ["day-1"])
    }

    /// Why the portal clears `versionFilter` when the app filter changes.
    @Test("A version kept from another app silently empties the queue")
    func staleVersionEmptiesQueue() {

        #expect(names(board, filter(app: .app("BeeTunes"), version: "2.0")).isEmpty)
        #expect(PortalRequestFilter.availableVersions(in: board, appFilter: .app("BeeTunes")).contains("2.0") == false)
    }

    @Test("Versions offered are the selected app's, deduplicated, newest first, without blanks")
    func availableVersions() {

        let requests = board + [request("day-3", app: "BeeDay", version: "2.1"),
                                request("day-blank", app: "BeeDay", version: "")]

        #expect(PortalRequestFilter.availableVersions(in: requests, appFilter: .app("BeeDay")) == ["2.1", "2.0"])
        #expect(PortalRequestFilter.availableVersions(in: requests, appFilter: .all) == ["2.1", "2.0", "1.0"])
        #expect(PortalRequestFilter.availableVersions(in: requests, appFilter: .unscoped) == ["1.0"])
        #expect(PortalRequestFilter.availableVersions(in: [], appFilter: .all).isEmpty)
    }

    @Test("Search matches title, body and author ID, trimmed and case-insensitive")
    func search() {

        let requests = [request("a", title: "Dark Mode please"),
                        request("b", body: "The chart is too DARK"),
                        request("c", creator: "_abc123"),
                        request("d", title: "Unrelated")]

        #expect(names(requests, filter(search: "  dark ")) == ["a", "b"])
        #expect(names(requests, filter(search: "_ABC123")) == ["c"])
        #expect(names(requests, filter(search: "   ")) == ["a", "b", "c", "d"])
        #expect(names(requests, filter(search: "missing")).isEmpty)
    }

    @Test("Open means open and not hidden")
    func openQueue() {

        let requests = [request("open"),
                        request("hidden", moderation: .hidden),
                        request("progress", status: .inProgress)]

        #expect(names(requests, filter(queue: .open)) == ["open"])
        #expect(names(requests, filter(queue: .all)) == ["open", "hidden", "progress"])
    }

    @Test("Images lists requests whose images await review")
    func imagesQueue() {

        let requests = [request("pending", imageState: .pending), request("none")]

        #expect(names(requests, filter(queue: .images)) == ["pending"])
    }

    @Test("Reported lists requests with at least one report, and only that queue asks for counts")
    func reportedQueue() {

        let requests = [request("reported"), request("clean")]
        var asked: [String] = []

        let counter: (CKRecord.ID) -> Int = { id in

            asked.append(id.recordName)

            return id.recordName == "reported" ? 2 : 0
        }

        #expect(names(requests, filter(queue: .reported), reportCount: counter) == ["reported"])
        #expect(asked == ["reported", "clean"])

        asked = []

        _ = names(requests, filter(queue: .open), reportCount: counter)

        #expect(asked.isEmpty)
    }

    @Test("Every filter must pass at once")
    func combined() {

        let requests = [request("hit", app: "BeeDay", version: "2.1", title: "Crash on launch"),
                        request("wrong-app", app: "BeeTunes", version: "2.1", title: "Crash on launch"),
                        request("wrong-version", app: "BeeDay", version: "2.0", title: "Crash on launch"),
                        request("wrong-text", app: "BeeDay", version: "2.1", title: "Slow"),
                        request("wrong-queue", app: "BeeDay", version: "2.1", title: "Crash on launch", status: .complete)]

        #expect(names(requests, filter(app: .app("BeeDay"), version: "2.1", search: "crash", queue: .open)) == ["hit"])
    }
}
