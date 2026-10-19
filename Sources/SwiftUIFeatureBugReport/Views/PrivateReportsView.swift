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
/// The body of `PrivateReportsView`, built only once the gate has a prepared store.
struct PrivateReportsViewContent: View {

    @State private var store: FeedbackStore
    @State private var appFilter: AppFilter = .all

    private let scope: PrivateReportScope
    private let embedsNavigationStack: Bool

    init(store: FeedbackStore, scope: PrivateReportScope = .mine, embedsNavigationStack: Bool = true) {

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

    private var title: String { scope == .all ? loc("Private reports") : loc("My private reports") }

    @ViewBuilder private var list: some View {

        PrivateReportsList(store: store, scope: scope, appFilter: appFilter) {

            if scope == .all && store.container.isDeveloper {

                AppFilterPicker(selection: $appFilter, appIDs: store.privateReports.allReports.map(\.appID))
            }
        }
        .ownedNavigationTitle(Text(verbatim: title), ownsStack: embedsNavigationStack)
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

    /// The reports section's header for `.mine` - private-only mode's board titles it. `.all` always
    /// shows the count instead.
    let listTitle: LocalizedStringKey?

    let header: () -> Header

    /// The deletion request the confirmation dialog is asking about.
    @State private var pendingProcess: PrivateDeletionRequest?
    @State private var processing: Set<CKRecord.ID> = []

    /// The report the developer asked to delete from the queue, awaiting confirmation.
    @State private var pendingReportDeletion: PrivateReport?
    @State private var deletingReports: Set<CKRecord.ID> = []

    init(store: FeedbackStore,
         scope: PrivateReportScope,
         appFilter: AppFilter = .all,
         filter: PrivateQueueFilter = .all,
         searchText: String = "",
         listTitle: LocalizedStringKey? = nil,
         selection: Binding<CKRecord.ID?>? = nil,
         @ViewBuilder header: @escaping () -> Header) {

        self.store = store
        self.scope = scope
        self.appFilter = appFilter
        self.filter = filter
        self.searchText = searchText
        self.selection = selection
        self.listTitle = listTitle
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
                                             searchText: searchText,
                                             followUps: store.privateReports.followUpsByReport,
                                             developerUserRecordIDs: store.configuration.developerUserRecordIDs)

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

                Section { ProgressView(loc("Loading…")).frame(maxWidth: .infinity) }
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

                    if scope == .all { Text("\(reports.count) reports", bundle: .feedbackResources) }
                    else if let listTitle { Text(listTitle, bundle: .feedbackResources) }
                }
                .confirmationDialog(loc("Delete this private report?"),
                                    isPresented: Binding(get: { pendingReportDeletion != nil },
                                                         set: { if !$0 { pendingReportDeletion = nil } }),
                                    titleVisibility: .visible,
                                    presenting: pendingReportDeletion) { report in

                    Button(loc("Delete report"), role: .destructive) { deleteReport(report) }

                    Button(loc("Cancel"), role: .cancel) { pendingReportDeletion = nil }

                } message: { _ in Text(PrivateReportDetailView.deleteReportMessage) }
            }

            if let error = store.privateReports.error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .confirmationDialog(loc("Delete these private reports?"),
                            isPresented: Binding(get: { pendingProcess != nil },
                                                 set: { if !$0 { pendingProcess = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingProcess) { request in

            Button(loc("Delete"), role: .destructive) { process(request) }

            Button(loc("Cancel"), role: .cancel) { pendingProcess = nil }

        } message: { request in

            switch request.scope {

            case .all: Text("Every private report this person has sent is deleted, with its images, files and replies. This can't be undone.", bundle: .feedbackResources)
            case .reports: Text("The requested reports are deleted, with their images, files and replies. This can't be undone.", bundle: .feedbackResources)
            }
        }
    }

    /// In the developer's queue a row can also be deleted outright, after confirmation - a swipe on
    /// iOS, a context menu on both platforms. Submitters never get this; they request deletion.
    @ViewBuilder private func row(for report: PrivateReport) -> some View {

        if isDeveloperQueue {

            rowContent(for: report)
                .disabled(deletingReports.contains(report.id))
                .rowActions {

                    Button(role: .destructive, action: { pendingReportDeletion = report }) {

                        Label(loc("Delete report"), systemImage: "trash")
                    }
                }
        }
        else {

            rowContent(for: report)
        }
    }

    @ViewBuilder private func rowContent(for report: PrivateReport) -> some View {

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

                        case .all: Text("All private reports", bundle: .feedbackResources)
                        case .reports: Text("\(request.reportNames.count) reports", bundle: .feedbackResources)
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

                        Button(loc("Delete"), role: .destructive) { pendingProcess = request }
                    }
                }
            }

        } header: { Text("Deletion requests", bundle: .feedbackResources) }
          footer: { Text("People can't delete their own private reports, so they ask you to. Process these promptly.", bundle: .feedbackResources) }
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

    /// Developer only: deletes one whole report from the queue - see `PrivateReportService.deleteReport`.
    private func deleteReport(_ report: PrivateReport) {

        pendingReportDeletion = nil
        deletingReports.insert(report.id)

        Task {

            do {

                try await store.privateReports.deleteReport(report)

                if let selection, selection.wrappedValue == report.id { selection.wrappedValue = nil }
            }
            catch {

                store.privateReports.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            deletingReports.remove(report.id)
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


extension PrivateReportsList where Header == EmptyView {

    init(store: FeedbackStore,
         scope: PrivateReportScope,
         appFilter: AppFilter = .all,
         filter: PrivateQueueFilter = .all,
         searchText: String = "",
         listTitle: LocalizedStringKey? = nil,
         selection: Binding<CKRecord.ID?>? = nil) {

        self.init(store: store, scope: scope, appFilter: appFilter, filter: filter,
                  searchText: searchText, listTitle: listTitle, selection: selection, header: { EmptyView() })
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

                    Label(loc("\(report.replies.count) replies"), systemImage: "bubble.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !report.files.isEmpty {

                    Label(loc("\(report.files.count) files"), systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if isDeletionPending {

                    Label(loc("Deletion requested"), systemImage: "trash")
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

    /// The attachment the developer asked to remove, awaiting confirmation.
    @State private var pendingRemoval: PrivateAttachment?
    @State private var isRemovingAttachment = false

    /// Developer only: deleting the whole report.
    @State private var showingDeleteReportConfirmation = false
    @State private var isDeletingReport = false

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

        store.container.identityState == .ready && store.container.currentUserRecordID == openedBy
    }

    /// Once identity has settled on someone else (or no one), leave rather than keep a redacted screen.
    private func dismissIfIdentityChanged() {

        guard store.container.identityState != .resolving, !belongsToCurrentIdentity else { return }

        dismiss()
    }

    /// Reloads the report, dropping the result if the identity changed while it was in flight.
    private func reloadDetail() async {

        let loaded = await store.privateReports.loadDetail(report)

        // Deleted meanwhile - by the developer, or a processed deletion request. Nothing left to show.
        if store.privateReports.isKnownDeleted(report) {

            dismiss()
            return
        }

        if belongsToCurrentIdentity { report = loaded }
    }

    /// The portal's controls are offered to a developer in the developer's queue. The `dev` role is
    /// what actually authorises the writes.
    private var showsDeveloperControls: Bool { scope == .all && store.container.isDeveloper }

    private var title: String { scope == .all ? loc("Private report") : loc("My private report") }

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
        .ownedNavigationTitle(Text(verbatim: title), ownsStack: false)
        .inlineNavigationTitle()
        .onChange(of: store.container.identityState) { _, _ in dismissIfIdentityChanged() }
        .onChange(of: store.container.currentUserRecordID) { _, _ in dismissIfIdentityChanged() }
        .task { await reloadDetail() }
        .confirmationDialog(removalTitle,
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { attachment in

            Button(loc("Remove"), role: .destructive) { removeAttachment(attachment) }

            Button(loc("Cancel"), role: .cancel) { }

        } message: { _ in Text("It is deleted for the sender too. The report and its conversation are kept. This can't be undone.", bundle: .feedbackResources) }
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

        } footer: { Label(loc("Only you and the developer can see this."), systemImage: "lock") }

        if !report.imageURLs.isEmpty {

            Section {

                ImageGallery(urls: report.imageURLs, onDelete: imageRemovalAction)
            }
        }

        if !report.files.isEmpty { PrivateFileList(store: store, report: report, onDelete: fileRemovalAction) }

        conversationSection

        composerSection

        if showsDeveloperControls {

            developerSections

            deleteReportSection
        }

        if scope == .mine { deletionSection }

        if let error {

            Section { FeedbackErrorBanner(error: error, retry: nil) }
        }
    }

    // MARK: - Conversation

    /// The conversation after the report itself: trusted developer replies and the follow-ups
    /// `PrivateThread` accepts, oldest first.
    private var messages: [PrivateThreadMessage] { store.privateReports.messages(for: report) }

    @ViewBuilder private var conversationSection: some View {

        Section {

            if messages.isEmpty {

                Text("No replies yet.", bundle: .feedbackResources)
                    .foregroundStyle(.secondary)
            }
            else {

                ForEach(messages) { message in PrivateMessageRow(message: message, viewer: scope == .all ? .developer : .submitter) }
            }

        } header: { Text("Conversation", bundle: .feedbackResources) }
    }

    /// At the bottom of the conversation for both sides. A developer's message is stored on the report
    /// (`reply(to:message:)`); a submitter's is a `PrivateReply` record (`sendFollowUp`).
    @ViewBuilder private var composerSection: some View {

        if showsDeveloperControls {

            Section {

                FeedbackTextEditor(placeholder: "Reply privately to the person who sent this", text: $replyText)

                sendButton(title: "Send reply", action: sendReply)

            } footer: { Text("Only the person who sent this report can read your reply.", bundle: .feedbackResources) }
        }
        else if scope == .mine {

            Section {

                FeedbackTextEditor(placeholder: "Add a message for the developer", text: $replyText)
                    .disabled(!acceptsFollowUp)

                sendButton(title: "Send", action: sendFollowUp)

            } footer: {

                if acceptsFollowUp {

                    Text("Only you and the developer can see this conversation. Messages can't be edited once sent.", bundle: .feedbackResources)
                }
                else {

                    Text("This report is complete, so it no longer takes new messages. Send new feedback instead.", bundle: .feedbackResources)
                }
            }
        }
    }

    private var acceptsFollowUp: Bool {

        PrivateThread.acceptsFollowUp(report: report, currentUserRecordID: store.container.currentUserRecordID)
    }

    private func sendButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {

        Button(action: action) {

            HStack {

                Text(title, bundle: .feedbackResources)

                if isSending {

                    Spacer()

                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isSending
                  || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || (!showsDeveloperControls && !acceptsFollowUp))
    }

    private func sendFollowUp() {

        let message = replyText

        isSending = true
        error = nil

        Task {

            do {

                try await store.privateReports.sendFollowUp(message, on: report)

                replyText = ""

                // Not awaited: may show the one-time notification prompt, after the save.
                store.didSendPrivateFeedback()
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isSending = false
        }
    }

    /// Submitters cannot delete a private report - `_creator` has READ only, so that they cannot rewrite
    /// the developer's replies either - so they ask the developer to.
    @ViewBuilder private var deletionSection: some View {

        Section {

            if store.privateReports.isDeletionPending(report) {

                Label(loc("Deletion requested. The developer will delete this report."), systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            else {

                Button(role: .destructive, action: { showingDeletionConfirmation = true }) {

                    HStack {

                        Label(loc("Ask the developer to delete this"), systemImage: "trash")

                        if isRequestingDeletion {

                            Spacer()

                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isRequestingDeletion)
            }

        } footer: { Text("Only the developer can delete private reports. It stays visible to you until they do.", bundle: .feedbackResources) }
          .confirmationDialog(loc("Ask the developer to delete this report?"),
                              isPresented: $showingDeletionConfirmation,
                              titleVisibility: .visible) {

              Button(loc("Request deletion"), role: .destructive) { requestDeletion() }

              Button(loc("Cancel"), role: .cancel) { }

          } message: { Text("The report, its images, files and replies will be deleted once the developer processes your request.", bundle: .feedbackResources) }
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

            Picker(loc("Status"), selection: Binding(get: { report.status }, set: { setStatus($0) })) {

                ForEach(RequestStatus.allCases, id: \.self) { status in

                    Text(status.localised).tag(status)
                }
            }

        } header: { Text("Status", bundle: .feedbackResources) }

        Section {

            ForEach(report.environment.disclosureEntries, id: \.label.key) { entry in

                LabeledContent(String(localized: entry.label), value: entry.value)
            }

            ForEach(sortedMetadataKeys, id: \.self) { key in

                LabeledContent(key, value: report.metadata[key] ?? "")
            }

            LabeledContent { Text(report.creatorID).textSelection(.enabled) } label: { Text("Sender", bundle: .feedbackResources) }

        } header: { Text("Details", bundle: .feedbackResources) }
    }

    // MARK: - Deleting the report

    /// The confirmation's explanation, shared with the queue's swipe action.
    static var deleteReportMessage: String { loc("The report, its whole conversation and every image and file are permanently deleted, for the sender too. This can't be undone.") }

    /// Developer only, in the portal. Submitters get `deletionSection` instead.
    @ViewBuilder private var deleteReportSection: some View {

        Section {

            Button(role: .destructive, action: { showingDeleteReportConfirmation = true }) {

                HStack {

                    Label(loc("Delete report"), systemImage: "trash")

                    if isDeletingReport {

                        Spacer()

                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isDeletingReport)

        } footer: { Text("Deletes this report and its conversation for you and the sender.", bundle: .feedbackResources) }
          .confirmationDialog(loc("Delete this private report?"),
                              isPresented: $showingDeleteReportConfirmation,
                              titleVisibility: .visible) {

              Button(loc("Delete report"), role: .destructive) { deleteReport() }

              Button(loc("Cancel"), role: .cancel) { }

          } message: { Text(Self.deleteReportMessage) }
    }

    private func deleteReport() {

        isDeletingReport = true
        error = nil

        Task {

            do {

                try await store.privateReports.deleteReport(report)

                isDeletingReport = false
                dismiss()
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
                isDeletingReport = false
            }
        }
    }

    // MARK: - Removing attachments

    /// Only in the portal, and not while a removal is in flight - positions shift once it lands.
    private var removesAttachments: Bool { showsDeveloperControls && !isRemovingAttachment }

    /// Asks for confirmation first - see `confirmationDialog` in `body`. `nil` hides the controls.
    private var imageRemovalAction: ((Int) -> Void)? {

        guard removesAttachments else { return nil }

        let count = report.imageURLs.count

        return { index in pendingRemoval = .image(index: index, count: count) }
    }

    private var fileRemovalAction: ((PrivateFile) -> Void)? {

        guard removesAttachments else { return nil }

        return { file in pendingRemoval = .file(file) }
    }

    private var removalTitle: Text {

        switch pendingRemoval {

        case .file(let file): return Text("Remove “\(file.name)”?", bundle: .feedbackResources)
        case .image, nil: return Text("Remove this image?", bundle: .feedbackResources)
        }
    }

    /// Developer only: deletes one attachment to save storage. Patched in rather than reloaded, so the
    /// remaining images are not downloaded again.
    private func removeAttachment(_ attachment: PrivateAttachment) {

        pendingRemoval = nil
        isRemovingAttachment = true
        error = nil

        Task {

            do {

                let updated = try await store.privateReports.removeAttachment(attachment, from: report)

                if belongsToCurrentIdentity { report = updated }
            }
            catch let refusal as AttachmentRemovalError {

                // Something else changed the attachments: show what is there now.
                if refusal.isStale { await reloadDetail() }

                self.error = .underlying(refusal.errorDescription ?? "")
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isRemovingAttachment = false
        }
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


/// One message in a private conversation. The viewer's own messages sit on the trailing side.
struct PrivateMessageRow: View {

    let message: PrivateThreadMessage

    /// Who is looking: the submitter in "My private reports", a developer in the portal.
    let viewer: PrivateMessageAuthor

    private var isOwn: Bool { message.author == viewer }

    private var authorLabel: String {

        switch (message.author, viewer) {

        case (.submitter, .submitter): return loc("You")
        case (.submitter, .developer): return loc("Sender")
        case (.developer, _): return loc("Developer")
        }
    }

    var body: some View {

        HStack {

            if isOwn { Spacer(minLength: 40) }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {

                Text(authorLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isOwn ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 10))

                Text(message.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isOwn { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
    }
}


/// A public entry point. Its initialisers only store their arguments, so constructing it - which
/// SwiftUI does eagerly for `NavigationLink(destination:)` - does no work at all.
public struct PrivateReportsView: View {

    private let source: FeedbackStoreSource
    private let scope: PrivateReportScope
    private let embedsNavigationStack: Bool

    /// Stores its arguments and nothing else. The store, and with it the `CKContainer`, is created
    /// only when this view is displayed - see `FeedbackStoreGate`.
    public init(configuration: FeedbackConfiguration,
                scope: PrivateReportScope = .mine,
                embedsNavigationStack: Bool = true) {

        self.source = .configuration(configuration)
        self.scope = scope
        self.embedsNavigationStack = embedsNavigationStack
    }

    public init(store: FeedbackStore, scope: PrivateReportScope = .mine, embedsNavigationStack: Bool = true) {

        self.source = .store(store)
        self.scope = scope
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {

        FeedbackStoreGate(source: source) { store in PrivateReportsViewContent(store: store, scope: scope, embedsNavigationStack: embedsNavigationStack) }
    }
}
