//
//  DeveloperPortalView.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import SwiftUI

enum PortalQueue: String, CaseIterable, Hashable {

    case open
    case reported
    case images
    case all

    var localised: LocalizedStringKey {

        switch self {

        case .open: return "Open"
        case .reported: return "Reported"
        case .images: return "Images"
        case .all: return "All"
        }
    }

    var symbolName: String {

        switch self {

        case .open: return "tray"
        case .reported: return "flag"
        case .images: return "photo"
        case .all: return "list.bullet"
        }
    }
}


/// Developer-facing triage: public requests and, when `privateFeedback` is on, the private reports
/// queue, behind one Public / Private switch. The app filter and search are shared by both; the
/// version filter and the Open/Reported/Images/All queues apply to public requests, Pending/All to
/// private ones. The Private tab's label carries the pending figure (`PrivateQueuePolicy`).
///
/// In `PrivateFeedbackMode.only` there is no public queue: the switch is hidden and the portal is the
/// private queue alone.
///
/// Shipping this view in every build is not a security hole: `FeedbackContainer.isDeveloper` decides
/// whether it is *offered*, and the `dev` security role decides whether its writes are *accepted*.
public struct DeveloperPortalView: View {

    @State private var store: FeedbackStore

    @State private var segment: PortalSegment = .requests
    @State private var queue: PortalQueue = .open
    @State private var privateFilter: PrivateQueueFilter = .pending
    @State private var versionFilter: String?
    @State private var appFilter: AppFilter = .all
    // Selected by ID, not by value: the struct is replaced wholesale on every reload,
    // so a value-based selection would silently drop each time the board refreshes.
    @State private var selection: CKRecord.ID?
    @State private var privateSelection: CKRecord.ID?
    @State private var searchText = ""

    /// The request the delete confirmation is asking about. Held here rather than on the row so the
    /// dialog survives the list re-sorting underneath it.
    @State private var pendingDeletion: FeedbackRequest?

    private let embedsNavigationStack: Bool

    public init(configuration: FeedbackConfiguration, embedsNavigationStack: Bool = true) {

        self.init(store: FeedbackStore(configuration: configuration), embedsNavigationStack: embedsNavigationStack)
    }

    public init(store: FeedbackStore, embedsNavigationStack: Bool = true) {

        self.store = store
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {

        container
            // The version picker lists only the selected app's versions; a version kept from the
            // previous app would silently empty the queue (or hide the picker that could clear it).
            // Selections are cleared too: the detail panes resolve them from every loaded record,
            // so a request or private report picked under the previous app would stay open (and
            // actionable) while the list shows a different app.
            .onChange(of: appFilter) { _, _ in
                versionFilter = nil
                selection = nil
                privateSelection = nil
            }
            .task {

                if !store.hasLoadedOnce { await store.start() }

                // An `if` rather than the `guard` this replaced: the portal is usually reached from
                // the board's toolbar, so the board has already loaded and a `guard` would return
                // before ever reaching the line below. Placed after `start` so identity has resolved
                // and `isDeveloper` is answerable.
                await store.askForDeveloperNotificationsIfNeeded()

                // Loaded up front rather than when the Private tab is first opened, so its badge is
                // right before anyone taps it.
                if offersPrivateFeedback { await store.privateReports.loadAllReports() }
            }
            .confirmationDialog("Delete request?",
                                isPresented: Binding(get: { pendingDeletion != nil },
                                                     set: { if !$0 { pendingDeletion = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDeletion) { request in

                Button("Delete", role: .destructive) {

                    Task {

                        await store.moderation.delete(request)

                        if selection == request.id { selection = nil }

                        pendingDeletion = nil
                    }
                }

                Button("Cancel", role: .cancel) { pendingDeletion = nil }

            } message: { request in

                Text("\"\(request.title)\" and its votes, replies, reports and metadata are removed. This can't be undone.")
            }
    }

    @ViewBuilder private var container: some View {

#if os(macOS)
        // Never a `NavigationSplitView` of its own, regardless of `embedsNavigationStack` - the only
        // known caller embeds this in another split view's detail column (via `FeedbackBoardView`'s
        // toolbar menu), and nesting one split view inside another's detail is not supported. A plain
        // `HStack` gets the same side-by-side look without being one, so it nests cleanly. See the
        // matching fix and its longer explanation on `FeedbackBoardView.container`.
        HStack(spacing: 0) {

            queueList
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)

            Divider()

            Group {

                switch activeSegment {

                case .requests:

                    if let selected = selectedRequest {

                        // Its own `NavigationStack` so its toolbar and refresh action stay scoped to this
                        // pane rather than merging into the queue list's.
                        NavigationStack { PortalRequestView(store: store, request: selected) }
                            .id(selected.id)
                    }
                    else {

                        FeedbackEmptyState(symbol: "hammer",
                                           title: "Nothing selected",
                                           message: "Pick a request from the list.")
                    }

                case .privateReports:

                    // Beside the list, like a public request - not pushed inside the list's pane.
                    if let selected = selectedPrivateReport {

                        NavigationStack { PrivateReportDetailView(store: store, report: selected, scope: .all) }
                            .id(selected.id)
                    }
                    else {

                        FeedbackEmptyState(symbol: "lock.shield",
                                           title: "Nothing selected",
                                           message: "Pick a private report from the list.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
#else
        
        if embedsNavigationStack {

            NavigationStack { queueList }
        }
        else {

            queueList
        }
#endif
    }

    @ViewBuilder private var queueList: some View {

#if os(macOS)
        // Plain content, not `.searchable`/`.feedbackRefreshable` - nested this deep inside a host's
        // own split view detail column, macOS has been seen merging and re-rendering those per-column
        // toolbar contributions, producing duplicate search fields and refresh buttons. See the
        // matching fix on `FeedbackBoardView.board`.
        VStack(spacing: 0) {
            
            VStack(spacing: 8) {
                
                HStack(spacing: 10) {

                    HStack(spacing: 4) {

                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                    Spacer(minLength: 8)

                    AppFilterPicker(selection: $appFilter, appIDs: filterableAppIDs)

                    if activeSegment == .requests { versionMenu }

                    Button(action: { Task { await Self.refresh(store: store, includesPrivate: offersPrivateFeedback) } }) {

                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
                
                if showsSegmentPicker { segmentPicker }

                switch activeSegment {

                case .requests: listFilter
                case .privateReports: privateFilterPicker
                }
            }
            .padding([.horizontal, .top], 12)

            segmentList
        }
        .ownedNavigationTitle("Dev Portal", ownsStack: embedsNavigationStack)
#else
        segmentList
            .navigationTitle("Dev Portal")
            .searchable(text: $searchText, prompt: Text("Search"))
            .feedbackRefreshable { [store, includesPrivate = offersPrivateFeedback] in

                await Self.refresh(store: store, includesPrivate: includesPrivate)
            }
            .toolbar {

                if AppFilterPicker.isVisible(selection: appFilter, appIDs: filterableAppIDs) {

                    ToolbarItem(placement: toolbarTrailingPlacement) {

                        AppFilterPicker(selection: $appFilter, appIDs: filterableAppIDs)
                    }
                }

                if activeSegment == .requests && !availableVersions.isEmpty {

                    ToolbarItem(placement: toolbarTrailingPlacement) { versionMenu }
                }
            }
#endif
    }

    @ViewBuilder private var segmentList: some View {

        switch activeSegment {

        case .requests: portalList
        case .privateReports: privateList
        }
    }

    /// The same list `PrivateReportsView` shows, fed the portal's shared app filter and search.
    @ViewBuilder private var privateList: some View {

#if os(macOS)
        PrivateReportsList(store: store,
                           scope: .all,
                           appFilter: appFilter,
                           filter: privateFilter,
                           searchText: searchText,
                           selection: $privateSelection)
#else
        PrivateReportsList(store: store,
                           scope: .all,
                           appFilter: appFilter,
                           filter: privateFilter,
                           searchText: searchText) {

            filterSection { privateFilterPicker }
        }
#endif
    }

    @ViewBuilder private var portalList: some View {

        // No `selection:` on the Mac - rows are buttons that set `selection` themselves (§ row(for:)).
#if os(macOS)
        List { portalRows }
#else
        List(selection: $selection) { portalRows }
#endif
    }
    
    @ViewBuilder private var listFilter: some View {
        
        // No visible "Queue" label - the row has zero insets so the control can span it, and a
        // leading label ate into that width and pushed the segments off-centre. Open/Reported/
        // Images/All read as a queue switch on sight, exactly as the board's filter does.
        Picker("", selection: $queue) {

            ForEach(PortalQueue.allCases, id: \.self) {

                Label($0.localised, systemImage: $0.symbolName).tag($0)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Triage queue"))
        .frame(maxWidth: .infinity, minHeight: 50)
    }

    /// Public / Private. Only drawn when private feedback is on - with it `.disabled` the schema may
    /// not have `PrivateReport` at all, and the portal is public requests only, as before.
    @ViewBuilder private var segmentPicker: some View {

        Picker("", selection: $segment) {

            Text("Public").tag(PortalSegment.requests)

            privateSegmentTitle.tag(PortalSegment.privateReports)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Public requests or private reports"))
        .frame(maxWidth: .infinity, minHeight: 36)
    }

    /// A segmented control draws text only, so the pending figure goes in the title.
    private var privateSegmentTitle: Text {

        let pending = privatePendingCount

        return pending > 0 ? Text("Private (\(pending))") : Text("Private")
    }

    @ViewBuilder private var privateFilterPicker: some View {

        Picker("", selection: $privateFilter) {

            ForEach(PrivateQueueFilter.allCases, id: \.self) {

                Label($0.localised, systemImage: $0.symbolName).tag($0)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Private queue"))
        .frame(maxWidth: .infinity, minHeight: 50)
    }

    /// The iOS lists' first rows: the Public / Private switch, then the segment's own queue filter.
    @ViewBuilder private func filterSection<Filter: View>(@ViewBuilder _ filter: () -> Filter) -> some View {

        Section {

            VStack(spacing: 0) {

                if showsSegmentPicker { segmentPicker }

                filter()
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .compactSectionSpacing()
    }

    @ViewBuilder private var portalRows: some View {

#if os(iOS)
        filterSection { listFilter }
#endif

        if let error = store.moderation.error {

            Section { FeedbackErrorBanner(error: error, retry: nil) }
        }

        if queued.isEmpty {

            Section {

                FeedbackEmptyState(symbol: queue.symbolName,
                                   title: "Nothing here",
                                   message: "This queue is empty.")
            }
        }
        else {

            Section {

                ForEach(queued) { request in row(for: request) }

            } header: { Text("^[\(queued.count) request](inflect: true)") }
        }
    }

    /// Lives in the header rather than as a list row - it is a filter over the list, and as a row it
    /// pushed the requests themselves below the fold before a single one had been read.
    @ViewBuilder private var versionMenu: some View {

        if !availableVersions.isEmpty {

            Picker("App version", selection: $versionFilter) {

                Text("All versions").tag(String?.none)

                ForEach(availableVersions, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .accessibilityLabel(Text("Filter by app version"))
            .help("Filter by app version")
#if os(macOS)
            .fixedSize()
#endif
        }
    }


    @ViewBuilder private func row(for request: FeedbackRequest) -> some View {

        let content = VStack(alignment: .leading, spacing: 4) {

            HStack {

                Text(request.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                Spacer(minLength: 8)

                AppBadge(appID: request.appID)

                TypeBadge(type: request.type)
            }

            HStack(spacing: 6) {

                StatusBadge(status: request.status)

                if store.reports.reportCount(for: request.id) > 0 {

                    Label("\(store.reports.reportCount(for: request.id))", systemImage: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if request.imageState == .pending {

                    Label("Image", systemImage: "photo")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if request.moderation == .hidden {

                    Label("Hidden", systemImage: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("^[\(store.votes.tally(for: request.id)) vote](inflect: true) · \(request.environment.versionLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

#if os(macOS)
        // A button, not a selectable row - `List(selection:)` draws its own highlight and focus ring,
        // which is the mismatched shape that showed up behind a selected row.
        //
        // Styled as the same card the board uses, deliberately: triage and the public board show the
        // same requests, and a row that looks different in the portal reads as a different kind of
        // thing. See `FeedbackBoardView.row(for:)`, which this mirrors.
        Button(action: { selection = request.id }) {

            content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selection == request.id ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                    : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {

                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: selection == request.id ? 1.5 : 0)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(selection == request.id ? [.isSelected] : [])
        .rowActions { rowMenu(for: request) }
#else
        NavigationLink { PortalRequestView(store: store, request: request) }
            label: { content }
            .rowActions { rowMenu(for: request) }
#endif
    }

    @ViewBuilder private func rowMenu(for request: FeedbackRequest) -> some View {

        if request.moderation == .hidden {

            Button(action: { Task { await store.moderation.unhide(request) } },
                   label: { Label("Unhide", systemImage: "eye") })
        }
        else {

            Button(role: .destructive, action: { Task { await store.moderation.hide(request) } },
                   label: { Label("Hide", systemImage: "eye.slash") })
        }

        Button(action: { Task { await store.moderation.approve(request) } },
               label: { Label("Clear reports", systemImage: "checkmark.shield") })

        Divider()

        // Confirmed rather than immediate: this cascades, and there is no undo. Hiding is the
        // reversible option and sits above it for that reason.
        Button(role: .destructive, action: { pendingDeletion = request },
               label: { Label("Delete", systemImage: "trash") })
    }

    private var selectedRequest: FeedbackRequest? {

        guard let selection else { return nil }

        return store.requests.requests.first { $0.id == selection }
    }

    private var selectedPrivateReport: PrivateReport? {

        guard let privateSelection else { return nil }

        return store.privateReports.allReports.first { $0.id == privateSelection }
    }

    // MARK: - Segments

    /// The same gate the board uses for its private entries.
    private var offersPrivateFeedback: Bool { store.configuration.privateFeedback.offersPrivateReports }

    /// `PrivateFeedbackMode.only` has no public requests to triage, so the portal is the private queue.
    private var offersPublicQueue: Bool { store.hasPublicBoard }

    /// Public / Private only when there are both.
    private var showsSegmentPicker: Bool { offersPrivateFeedback && offersPublicQueue }

    /// Never the Private tab while private feedback is off, and never the Public one in private-only
    /// mode, whatever `segment` was left on.
    private var activeSegment: PortalSegment {

        guard offersPublicQueue else { return .privateReports }

        return offersPrivateFeedback ? segment : .requests
    }

    /// The figure on the Private tab, narrowed by the shared app filter - see `PrivateQueuePolicy`.
    private var privatePendingCount: Int {

        offersPrivateFeedback ? store.privateReports.pendingCount(appFilter: appFilter) : 0
    }

    /// Both segments' apps, so the one shared filter offers every app either list could show and a
    /// selection made on one tab stays valid on the other.
    private var filterableAppIDs: [String?] {

        (offersPublicQueue ? store.requests.requests.map(\.appID) : [])
            + (offersPrivateFeedback ? store.privateReports.allReports.map(\.appID) : [])
    }

    /// `store.load()` reads nothing public in private-only mode - see `FeedbackStore.load()`.
    private static func refresh(store: FeedbackStore, includesPrivate: Bool) async {

        await store.load()

        if includesPrivate { await store.privateReports.loadAllReports() }
    }

    // MARK: - Queues

    /// The portal sees hidden and over-threshold requests too - the client-side visibility rule is for
    /// users, not for the person who has to moderate.
    private var queued: [FeedbackRequest] {

        let filter = PortalRequestFilter(appFilter: appFilter,
                                         versionFilter: versionFilter,
                                         searchText: searchText,
                                         queue: queue)

        return store.requests.requests
            .filter { request in filter.includes(request, reportCount: { store.reports.reportCount(for: $0) }) }
            .sorted { store.votes.tally(for: $0.id) > store.votes.tally(for: $1.id) }
    }

    private var availableVersions: [String] {

        PortalRequestFilter.availableVersions(in: store.requests.requests, appFilter: appFilter)
    }
}
