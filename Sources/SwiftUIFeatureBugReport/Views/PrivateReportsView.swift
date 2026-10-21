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
/// The board offers `.mine` only. The developer's queue lives in `DeveloperPortalView`'s Private tab,
/// which embeds the same `PrivateReportsList`; `.all` stays here for hosts that show it on its own.
///
/// Rows push a detail view, so on the Mac this always owns a `NavigationStack` of its own - the pushes
/// stay inside this view instead of replacing the host's content (see `BoardDestination`).
public struct PrivateReportsView: View {

    @State private var store: FeedbackStore
    @State private var appFilter: AppFilter = .all

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

    private var title: LocalizedStringKey { scope == .all ? "Private reports" : "My private reports" }

    @ViewBuilder private var list: some View {

        PrivateReportsList(store: store, scope: scope, appFilter: appFilter) {

            if scope == .all && store.container.isDeveloper {

                AppFilterPicker(selection: $appFilter, appIDs: store.privateReports.allReports.map(\.appID))
            }
        }
        .ownedNavigationTitle(title, ownsStack: embedsNavigationStack)
        .inlineNavigationTitle()
        .feedbackRefreshable { [store, scope] in await store.privateReports.load(scope) }
        .task {

            await store.start()
            await store.privateReports.load(scope)
        }
    }
}


/// The private reports list itself, without navigation, title, loading or refresh - those belong to
/// whoever embeds it: `PrivateReportsView` on its own, or `DeveloperPortalView`'s Private tab.
///
/// `header` is rendered as the list's first rows, so a host can put its own filter controls inside the
/// scrolling list the way the portal's public queue does.
///
/// With `selection` set, rows select instead of pushing - the Mac portal shows the detail beside the
/// list, as it does for public requests, rather than pushing inside a pane.
struct PrivateReportsList<Header: View>: View {

    let store: FeedbackStore
    let scope: PrivateReportScope

    let appFilter: AppFilter
    let filter: PrivateQueueFilter
    let searchText: String
    let selection: Binding<CKRecord.ID?>?

    let header: () -> Header

    /// The deletion request the confirmation dialog is asking about.
    @State private var pendingProcess: PrivateDeletionRequest?
    @State private var processing: Set<CKRecord.ID> = []

    init(store: FeedbackStore,
         scope: PrivateReportScope,
         appFilter: AppFilter = .all,
         filter: PrivateQueueFilter = .all,
         searchText: String = "",
         selection: Binding<CKRecord.ID?>? = nil,
         @ViewBuilder header: @escaping () -> Header) {

        self.store = store
        self.scope = scope
        self.appFilter = appFilter
        self.filter = filter
        self.searchText = searchText
        self.selection = selection
        self.header = header
    }

    private var isDeveloperQueue: Bool { scope == .all && store.container.isDeveloper }

    private var reports: [PrivateReport] {

        switch scope {

        case .all:
            return PrivateQueuePolicy.queued(store.privateReports.allReports,
                                             deletionRequests: store.privateReports.pendingDeletionRequests,
                                             appFilter: appFilter,
                                             filter: filter,
                                             searchText: searchText)

        case .mine:
            return store.privateReports.myReports
        }
    }

    /// Whether the queue is empty because of a filter rather than because nothing exists.
    private var isFilteredEmpty: Bool {

        scope == .all && !store.privateReports.allReports.isEmpty
    }

    var body: some View {

        List {

            header()

            if isDeveloperQueue && !store.privateReports.pendingDeletionRequests.isEmpty {

                deletionRequestsSection
            }

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
            else if reports.isEmpty && isFilteredEmpty {

                Section {

                    FeedbackEmptyState(symbol: filter.symbolName,
                                       title: "Nothing here",
                                       message: filter == .pending ? "No private reports are waiting on you."
                                                                   : "No private reports match.")
                }
            }
            else if reports.isEmpty {

                Section {

                    FeedbackEmptyState(symbol: "lock",
                                       title: "No private reports",
                                       message: "Feedback sent privately shows up here. Only you and the developer can see it.")
                }
            }
            else {

                Section {

                    ForEach(reports) { report in row(for: report) }

                } header: {

                    if scope == .all { Text("^[\(reports.count) report](inflect: true)") }
                }
            }

            if let error = store.privateReports.error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .confirmationDialog("Delete these private reports?",
                            isPresented: Binding(get: { pendingProcess != nil },
                                                 set: { if !$0 { pendingProcess = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingProcess) { request in

            Button("Delete", role: .destructive) { process(request) }

            Button("Cancel", role: .cancel) { pendingProcess = nil }

        } message: { request in

            switch request.scope {

            case .all: Text("Every private report this person has sent is deleted, with its images and replies. This can't be undone.")
            case .reports: Text("The requested reports are deleted, with their images and replies. This can't be undone.")
            }
        }
    }

    @ViewBuilder private func row(for report: PrivateReport) -> some View {

        let content = PrivateReportRow(report: report,
                                       showsCreator: scope == .all,
                                       showsApp: scope == .all,
                                       isDeletionPending: store.privateReports.isDeletionPending(report))

        if let selection {

            let isSelected = selection.wrappedValue == report.id

            // The same card as the portal's public rows - see `DeveloperPortalView.row(for:)`.
            Button(action: { selection.wrappedValue = report.id }) {

                content
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                           : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {

                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        else {

            NavigationLink {

                PrivateReportDetailView(store: store, report: report, scope: scope)

            } label: { content }
        }
    }

    /// Developer only. Users who cannot delete their own private reports ask here instead.
    @ViewBuilder private var deletionRequestsSection: some View {

        Section {

            ForEach(store.privateReports.pendingDeletionRequests) { request in

                HStack(alignment: .firstTextBaseline) {

                    VStack(alignment: .leading, spacing: 3) {

                        switch request.scope {

                        case .all: Text("All private reports")
                        case .reports: Text("^[\(request.reportNames.count) report](inflect: true)")
                        }

                        Text(request.requesterID)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)

                        Text(request.requestedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)

                    if processing.contains(request.id) {

                        ProgressView().controlSize(.small)
                    }
                    else {

                        Button("Delete", role: .destructive) { pendingProcess = request }
                    }
                }
            }

        } header: { Text("Deletion requests") }
          footer: { Text("People can't delete their own private reports, so they ask you to. Process these promptly.") }
    }

    private func process(_ request: PrivateDeletionRequest) {

        pendingProcess = nil
        processing.insert(request.id)

        Task {

            do {

                try await store.privateReports.process(request)
            }
            catch {

                store.privateReports.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            processing.remove(request.id)
        }
    }

}


extension PrivateReportService {

    /// The load each scope's list shows.
    func load(_ scope: PrivateReportScope) async {

        switch scope {

        case .mine: await loadMine()
        case .all: await loadAllReports()
        }
    }
}


/// When an open or selected private report has to be let go.
///
/// A detail view or a selection holds on to a report that `PrivateReportService.reset()` cannot reach,
/// so after a sign-out, an account switch or a reload that dropped the report, it would keep showing
/// the previous content. Pure, so the rules are tested without a view.
enum PrivateReportPresentation {

    /// The signed-in identity, as one value to observe: a change to either part invalidates what is open.
    struct Identity: Equatable {

        let state: IdentityState
        let userRecordID: String?
    }

    /// Whether a report opened by `openedBy` may still be shown. False while identity is resolving,
    /// for a report opened before identity resolved, and after a sign-out or an account switch.
    static func isShowable(openedBy: String?, current: Identity) -> Bool {

        current.state == .ready && openedBy != nil && current.userRecordID == openedBy
    }

    /// The selection to keep once the loaded reports changed: `nil` when the selected report is no
    /// longer among them, so a later reload cannot bring a stale selection back.
    static func retainedSelection(_ selection: CKRecord.ID?, in reports: [PrivateReport]) -> CKRecord.ID? {

        guard let selection, reports.contains(where: { $0.id == selection }) else { return nil }

        return selection
    }
}


extension FeedbackContainer {

    /// The identity private report screens are bound to - see `PrivateReportPresentation`.
    var privateReportIdentity: PrivateReportPresentation.Identity {

        PrivateReportPresentation.Identity(state: identityState, userRecordID: currentUserRecordID)
    }
}


extension PrivateReportService {

    /// The loaded reports a scope's list is built from, before any filter or search.
    func loadedReports(_ scope: PrivateReportScope) -> [PrivateReport] {

        switch scope {

        case .mine: myReports
        case .all: allReports
        }
    }
}


extension PrivateReportsList where Header == EmptyView {

    init(store: FeedbackStore,
         scope: PrivateReportScope,
         appFilter: AppFilter = .all,
         filter: PrivateQueueFilter = .all,
         searchText: String = "",
         selection: Binding<CKRecord.ID?>? = nil) {

        self.init(store: store, scope: scope, appFilter: appFilter, filter: filter,
                  searchText: searchText, selection: selection, header: { EmptyView() })
    }
}



struct PrivateReportRow: View {

    let report: PrivateReport
    let showsCreator: Bool
    var showsApp = false
    var isDeletionPending = false

    var body: some View {

        VStack(alignment: .leading, spacing: 4) {

            Text(report.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 6) {

                if showsApp { AppBadge(appID: report.appID) }

                TypeBadge(type: report.kind)
                StatusBadge(status: report.status)

                if !report.replies.isEmpty {

                    Label("^[\(report.replies.count) reply](inflect: true)", systemImage: "bubble.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if isDeletionPending {

                    Label("Deletion requested", systemImage: "trash")
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

    @State private var showingDeletionConfirmation = false
    @State private var isRequestingDeletion = false

    @Environment(\.dismiss) private var dismiss

    private let scope: PrivateReportScope

    /// The identity that opened this report. `PrivateReportService.reset()` cannot clear the snapshot
    /// held here, so the content is only shown while this is still the signed-in identity. `@State`
    /// so a re-created view value keeps the first identity instead of adopting the new one.
    @State private var openedBy: String?

    init(store: FeedbackStore, report: PrivateReport, scope: PrivateReportScope) {

        _store = State(initialValue: store)
        _report = State(initialValue: report)
        self.scope = scope
        _openedBy = State(initialValue: store.container.currentUserRecordID)
    }

    /// False while identity is resolving and after a sign-out or account switch.
    private var belongsToCurrentIdentity: Bool {

        PrivateReportPresentation.isShowable(openedBy: openedBy, current: store.container.privateReportIdentity)
    }

    /// While identity is resolving the content is only redacted (see `body`), since it may settle on
    /// the same account. Once it has settled on someone else (or no one), the snapshot is dropped - not
    /// just hidden - and the view leaves rather than keep a redacted screen. A host that shows it
    /// beside a list (the Mac portal) clears its selection as well, since `dismiss` has nothing to
    /// pop there.
    private func identityChanged() {

        guard !belongsToCurrentIdentity, store.container.identityState != .resolving else { return }

        clearSnapshot()
        dismiss()
    }

    /// Whether the list this report was opened from still contains it.
    private var isStillListed: Bool {

        PrivateReportPresentation.retainedSelection(report.id, in: store.privateReports.loadedReports(scope)) != nil
    }

    /// The list reloaded without this report - deleted, or gone with the identity that loaded it.
    private func listChanged() {

        guard !isStillListed else { return }

        clearSnapshot()
        dismiss()
    }

    /// Replaces the report with an empty one under the same ID, so its text, replies, images and
    /// metadata are no longer held by this view.
    private func clearSnapshot() {

        report = PrivateReport(id: report.id)
        replyText = ""
        error = nil
    }

    /// Reloads the report, dropping the result if the identity changed or the report left the list
    /// while it was in flight, so a pending load cannot restore content that was already cleared.
    private func reloadDetail() async {

        let loaded = await store.privateReports.loadDetail(report)

        if belongsToCurrentIdentity, isStillListed { report = loaded }
    }

    /// The portal's controls are offered to a developer in the developer's queue. The `dev` role is
    /// what actually authorises the writes.
    private var showsDeveloperControls: Bool { scope == .all && store.container.isDeveloper }

    private var title: LocalizedStringKey { scope == .all ? "Private report" : "My private report" }

    /// Developer-supplied keys, shown verbatim - they are the integrator's own identifiers.
    private var sortedMetadataKeys: [String] { report.metadata.keys.sorted() }

    var body: some View {

        Form {

            if belongsToCurrentIdentity {

                reportSections
            }
            else {

                Section { IdentityResolvingView() }
            }
        }
        .formStyle(.grouped)
        // Never renames a Mac host window - see `ownedNavigationTitle`.
        .ownedNavigationTitle(title, ownsStack: false)
        .inlineNavigationTitle()
        .onChange(of: store.container.privateReportIdentity) { _, _ in identityChanged() }
        .onChange(of: store.privateReports.loadedReports(scope).map(\.id)) { _, _ in listChanged() }
        .task { await reloadDetail() }
    }

    @ViewBuilder private var reportSections: some View {

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

        if scope == .mine { deletionSection }

        if let error {

            Section { FeedbackErrorBanner(error: error, retry: nil) }
        }
    }

    /// Submitters cannot delete a private report - `_creator` has READ only, so that they cannot rewrite
    /// the developer's replies either - so they ask the developer to.
    @ViewBuilder private var deletionSection: some View {

        Section {

            if store.privateReports.isDeletionPending(report) {

                Label("Deletion requested. The developer will delete this report.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            else {

                Button(role: .destructive, action: { showingDeletionConfirmation = true }) {

                    HStack {

                        Label("Ask the developer to delete this", systemImage: "trash")

                        if isRequestingDeletion {

                            Spacer()

                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isRequestingDeletion)
            }

        } footer: { Text("Only the developer can delete private reports. It stays visible to you until they do.") }
          .confirmationDialog("Ask the developer to delete this report?",
                              isPresented: $showingDeletionConfirmation,
                              titleVisibility: .visible) {

              Button("Request deletion", role: .destructive) { requestDeletion() }

              Button("Cancel", role: .cancel) { }

          } message: { Text("The report, its images and replies will be deleted once the developer processes your request.") }
    }

    private func requestDeletion() {

        isRequestingDeletion = true
        error = nil

        Task {

            do {

                try await store.privateReports.requestDeletion(of: report)
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isRequestingDeletion = false
        }
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

                // Reloaded rather than patched: a status-only edit to this copy would keep stale
                // replies and activity if a reply landed while the save was in flight.
                await reloadDetail()
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
                await reloadDetail()
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isSending = false
        }
    }
}
