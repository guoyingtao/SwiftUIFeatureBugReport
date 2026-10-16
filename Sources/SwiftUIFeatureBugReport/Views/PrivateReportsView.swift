//
//  PrivateReportsView.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import SwiftUI

/// Whose private reports a `PrivateReportsView` lists.
public enum PrivateReportScope: String, Sendable, Hashable {

    /// The signed-in user's own reports, with the developer's replies.
    case mine

    /// Every report. Developer only - the `dev` role is what lets CloudKit return other people's.
    case all
}


/// Private, developer-only submissions: "My private reports" for a user, or the developer's queue.
///
/// Rows push a detail view, so on the Mac this always owns a `NavigationStack` of its own - the pushes
/// stay inside this view instead of replacing the host's content (see `BoardDestination`).
public struct PrivateReportsView: View {

    @State private var store: FeedbackStore

    private let scope: PrivateReportScope
    private let embedsNavigationStack: Bool

    public init(configuration: FeedbackConfiguration,
                scope: PrivateReportScope = .mine,
                embedsNavigationStack: Bool = true) {

        self.init(store: FeedbackStore(configuration: configuration),
                  scope: scope,
                  embedsNavigationStack: embedsNavigationStack)
    }

    public init(store: FeedbackStore, scope: PrivateReportScope = .mine, embedsNavigationStack: Bool = true) {

        self.store = store
        self.scope = scope
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {

#if os(macOS)
        NavigationStack { list }
#else
        if embedsNavigationStack {

            NavigationStack { list }
        }
        else {

            list
        }
#endif
    }

    private var reports: [PrivateReport] {

        scope == .all ? store.privateReports.allReports : store.privateReports.myReports
    }

    private var title: LocalizedStringKey { scope == .all ? "Private reports" : "My private reports" }

    @ViewBuilder private var list: some View {

        List {

            if store.container.identityState == .resolving {

                Section { IdentityResolvingView() }
            }
            else if !store.canWrite {

                Section { ReadOnlyNotice() }
            }
            else if scope == .all && !store.container.isDeveloper {

                Section {

                    FeedbackEmptyState(symbol: "lock",
                                       title: "Developers only",
                                       message: "Only the developer can see everyone's private reports.")
                }
            }
            else if store.privateReports.isLoading && reports.isEmpty {

                Section { ProgressView("Loading…").frame(maxWidth: .infinity) }
            }
            else if reports.isEmpty {

                Section {

                    FeedbackEmptyState(symbol: "lock",
                                       title: "No private reports",
                                       message: "Feedback sent privately shows up here. Only you and the developer can see it.")
                }
            }
            else {

                ForEach(reports) { report in

                    NavigationLink {

                        PrivateReportDetailView(store: store, report: report, scope: scope)

                    } label: { PrivateReportRow(report: report, showsCreator: scope == .all) }
                }
            }

            if let error = store.privateReports.error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .ownedNavigationTitle(title, ownsStack: embedsNavigationStack)
        .inlineNavigationTitle()
        .feedbackRefreshable { [store, scope] in await Self.load(store: store, scope: scope) }
        .task {

            await store.start()
            await Self.load(store: store, scope: scope)
        }
    }

    private static func load(store: FeedbackStore, scope: PrivateReportScope) async {

        switch scope {

        case .mine: await store.privateReports.loadMine()
        case .all: await store.privateReports.loadAllReports()
        }
    }
}


struct PrivateReportRow: View {

    let report: PrivateReport
    let showsCreator: Bool

    var body: some View {

        VStack(alignment: .leading, spacing: 4) {

            Text(report.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 6) {

                TypeBadge(type: report.kind)
                StatusBadge(status: report.status)

                if !report.replies.isEmpty {

                    Label("^[\(report.replies.count) reply](inflect: true)", systemImage: "bubble.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {

                Text(report.lastActivityAt, format: .relative(presentation: .named))

                if showsCreator {

                    Text(report.creatorID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}


struct PrivateReportDetailView: View {

    @State private var store: FeedbackStore
    @State private var report: PrivateReport

    @State private var replyText = ""
    @State private var isSending = false
    @State private var error: FeedbackError?

    private let scope: PrivateReportScope

    init(store: FeedbackStore, report: PrivateReport, scope: PrivateReportScope) {

        _store = State(initialValue: store)
        _report = State(initialValue: report)
        self.scope = scope
    }

    /// The portal's controls are offered to a developer in the developer's queue. The `dev` role is
    /// what actually authorises the writes.
    private var showsDeveloperControls: Bool { scope == .all && store.container.isDeveloper }

    private var title: LocalizedStringKey { scope == .all ? "Private report" : "My private report" }

    /// Developer-supplied keys, shown verbatim - they are the integrator's own identifiers.
    private var sortedMetadataKeys: [String] { report.metadata.keys.sorted() }

    var body: some View {

        Form {

            Section {

                Text(report.title)
                    .font(.headline)
                    .textSelection(.enabled)

                HStack(spacing: 6) {

                    TypeBadge(type: report.kind)
                    StatusBadge(status: report.status)
                }

                Text(report.body)
                    .textSelection(.enabled)

            } footer: { Label("Only you and the developer can see this.", systemImage: "lock") }

            if !report.imageURLs.isEmpty {

                Section { ImageGallery(urls: report.imageURLs) }
            }

            Section {

                if report.replies.isEmpty {

                    Text("No replies yet.")
                        .foregroundStyle(.secondary)
                }
                else {

                    ForEach(Array(report.replies.enumerated()), id: \.offset) { _, reply in

                        VStack(alignment: .leading, spacing: 3) {

                            Text(reply.message)
                                .textSelection(.enabled)

                            Text(reply.createdAt, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            } header: { Text("Developer replies") }

            if showsDeveloperControls { developerSections }

            if let error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .formStyle(.grouped)
        // Never renames a Mac host window - see `ownedNavigationTitle`.
        .ownedNavigationTitle(title, ownsStack: false)
        .inlineNavigationTitle()
        .task { report = await store.privateReports.loadDetail(report) }
    }

    @ViewBuilder private var developerSections: some View {

        Section {

            Picker("Status", selection: Binding(get: { report.status }, set: { setStatus($0) })) {

                ForEach(RequestStatus.allCases, id: \.self) { status in

                    Text(status.localised).tag(status)
                }
            }

        } header: { Text("Status") }

        Section {

            FeedbackTextEditor(placeholder: "Reply privately to the person who sent this", text: $replyText)

            Button(action: { sendReply() }) {

                HStack {

                    Text("Send reply")

                    if isSending {

                        Spacer()

                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isSending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        } header: { Text("Reply") }
          footer: { Text("Only the person who sent this report can read your reply.") }

        Section {

            ForEach(report.environment.disclosureEntries, id: \.label.key) { entry in

                LabeledContent(String(localized: entry.label), value: entry.value)
            }

            ForEach(sortedMetadataKeys, id: \.self) { key in

                LabeledContent(key, value: report.metadata[key] ?? "")
            }

            LabeledContent { Text(report.creatorID).textSelection(.enabled) } label: { Text("Sender") }

        } header: { Text("Details") }
    }

    private func setStatus(_ status: RequestStatus) {

        guard status != report.status else { return }

        error = nil

        Task {

            do {

                try await store.privateReports.setStatus(status, on: report)

                report.status = status
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }
        }
    }

    private func sendReply() {

        let message = replyText

        isSending = true
        error = nil

        Task {

            do {

                try await store.privateReports.reply(to: report, message: message)

                replyText = ""
                report = await store.privateReports.loadDetail(report)
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isSending = false
        }
    }
}
