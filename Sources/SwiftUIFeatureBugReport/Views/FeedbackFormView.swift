//
//  FeedbackFormView.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct FeedbackFormView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var store: FeedbackStore

    @State private var type: FeedbackType
    @State private var title: String
    @State private var body_: String
    @State private var imageData: [Data] = []

    /// Files copied out of the picker's security scope - see `FileAttachmentPicker`. Private only.
    @State private var files: [PendingFileAttachment] = []

    /// The user's own choice. Whether the submission is actually private also depends on the mode -
    /// see `isPrivate`.
    @State private var privateChoice = false

    @State private var isSubmitting = false
    @State private var showSuccess = false

    /// The route the last successful submission actually took, captured when it started. The success
    /// alert reads this rather than `isPrivate`, which the user can change while the save is pending.
    @State private var submittedPrivately = false
    @State private var error: FeedbackError?

    @State private var matches: [FeedbackRequest] = []
    @State private var lastSearchedText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var votedFromSearch: FeedbackRequest?

    /// Defaults to on - the developer asked for this context, and it is only ever attached to a
    /// private, developer-only record. Off by choice, never by default.
    @State private var includeMetadata = true

    private let metadata: [String: String]
    private let embedsNavigationStack: Bool

    /// Fires at four characters or more, debounced. Below that the token search is all noise.
    private static let searchMinimumLength = 4
    private static let searchDebounce = Duration.milliseconds(450)

    public init(configuration: FeedbackConfiguration,
                prefill: FeedbackPrefill? = nil,
                embedsNavigationStack: Bool = true) {

        self.init(store: FeedbackStore(configuration: configuration),
                  prefill: prefill,
                  embedsNavigationStack: embedsNavigationStack)
    }

    public init(store: FeedbackStore,
                prefill: FeedbackPrefill? = nil,
                initialType: FeedbackType = .bug,
                embedsNavigationStack: Bool = true) {

        self.store = store
        self.metadata = prefill?.metadata ?? [:]
        self.embedsNavigationStack = embedsNavigationStack

        _type = State(initialValue: prefill?.type ?? initialType)
        _title = State(initialValue: prefill?.title ?? "")
        _body_ = State(initialValue: prefill?.body ?? "")
    }

    /// Title and body are both required. This stays required whatever a `FeedbackPrefill` supplied -
    /// prefilling is a convenience, not a way to submit an empty report.
    private var canSubmit: Bool {

        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
            && store.canWrite
    }

    private var privateMode: PrivateFeedbackMode { store.configuration.privateFeedback }

    private var isPrivateForced: Bool {

        PrivateFeedbackPolicy.isForced(mode: privateMode, type: type, hasAttachments: !imageData.isEmpty, hasFiles: !files.isEmpty)
    }

    private var isPrivate: Bool {

        PrivateFeedbackPolicy.isPrivate(mode: privateMode,
                                        type: type,
                                        hasAttachments: !imageData.isEmpty,
                                        hasFiles: !files.isEmpty,
                                        userChoice: privateChoice)
    }

    private var forcedReason: PrivateFeedbackPolicy.ForcedReason? {

        PrivateFeedbackPolicy.forcedReason(mode: privateMode, type: type, hasAttachments: !imageData.isEmpty, hasFiles: !files.isEmpty)
    }

    /// Offered whenever files are on and private reports exist; attaching one forces private.
    private var allowsFiles: Bool {

        PrivateFeedbackPolicy.allowsFiles(fileAttachmentsEnabled: store.configuration.allowFileAttachments, mode: privateMode)
    }

    private var allowsImages: Bool {

        PrivateFeedbackPolicy.allowsImages(publicAttachmentsAllowed: store.configuration.allowImageAttachments,
                                           isPrivate: isPrivate)
    }

    public var body: some View {

        if embedsNavigationStack {

            NavigationStack { form }
        }
        else {

            form
        }
    }

    @ViewBuilder private var form: some View {

        Form {

            if !store.canWrite && store.container.identityState != .resolving {

                Section { ReadOnlyNotice() }
            }

            Section {

                Picker("Type", selection: $type) {

                    Text("Bug").tag(FeedbackType.bug)
                    Text("Feature").tag(FeedbackType.feature)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Feedback type"))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .compactSectionSpacing()

            Section {

                TextField("Title", text: $title)
                    .onChange(of: title) { _, newValue in scheduleSearch(for: newValue) }

            } header: { Text("Title") }

            if !matches.isEmpty { searchResults }

            Section {

                FeedbackTextEditor(placeholder: "What happened, or what would you like to see?",
                                   text: $body_)

            } header: { Text("Details") }

            if PrivateFeedbackPolicy.offersToggle(mode: privateMode) { privateSection }
            else if privateMode == .only { privateOnlyNotice }

            if allowsImages {

                Section { ImageAttachmentPicker(imageData: $imageData) }
            }

            if allowsFiles {

                Section {

                    FileAttachmentPicker(files: $files, rules: store.configuration.fileAttachmentRules)

                } footer: {

                    if privateMode != .only && files.isEmpty && !isPrivate {

                        Text("Files are only ever sent privately. Attaching one makes this feedback private.")
                    }
                }
            }

            Section {

                NavigationLink {

                    MetadataDisclosureView(includeMetadata: $includeMetadata, environment: DeviceInfo.current(), metadata: metadata)

                } label: { Label("What gets included?", systemImage: "info.circle") }
            }

#if !os(macOS)
            Section {

                Button(action: { submit() }) {

                    HStack {

                        Text("Submit")

                        if isSubmitting {

                            Spacer()

                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(!canSubmit)
            }
#endif

            if let error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .formStyle(.grouped)
#if os(iOS)
        // Long bodies push the submit row under the keyboard; let a drag or the Done key dismiss it.
        .scrollDismissesKeyboard(.interactively)
#endif
        .navigationTitle("New Feedback")
        .inlineNavigationTitle()
        .toolbar {

            ToolbarItem(placement: toolbarLeadingPlacement) {

                Button("Cancel", role: .cancel) { dismiss() }
            }

#if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {

                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
#endif

#if os(macOS)
            // Native sheet convention: primary action bottom-right, not a full-width row inside the form.
            ToolbarItem(placement: .confirmationAction) {

                Button(action: { submit() }) {

                    if isSubmitting {

                        ProgressView().controlSize(.small)
                    }
                    else {

                        Text("Submit")
                    }
                }
                .disabled(!canSubmit)
            }
#endif
        }
        .onDisappear { searchTask?.cancel() }
        .task { await store.start() }

        .alert("Thanks", isPresented: $showSuccess) {

            Button("OK") { dismiss() }

        } message: {

            if submittedPrivately {

                Text("Your feedback has been sent privately. Only you and the developer can see it.")
            }
            else {

                Text("Your feedback has been submitted.")
            }
        }

        // Images picked for a private submission must not quietly ride along on a public one. If the
        // picker disappears, so do they.
        .onChange(of: allowsImages) { _, allowed in

            if !allowed { imageData = [] }
        }

        .alert("Voted", isPresented: .constant(votedFromSearch != nil)) {

            Button("OK") {

                votedFromSearch = nil
                dismiss()
            }

        } message: {

            Text("Your vote has been added to \"\(votedFromSearch?.title ?? "")\".")
        }
    }

    // MARK: - Private

    @ViewBuilder private var privateSection: some View {

        Section {

            Toggle(isOn: Binding(get: { isPrivate }, set: { privateChoice = $0 })) {

                Label("Private (only visible to developer)", systemImage: "lock")
            }
            .disabled(isPrivateForced)

        } footer: {

            if forcedReason == .files {

                Text("Feedback with a file attached is always sent privately. Remove the file to post publicly.")
            }
            else if isPrivateForced {

                Text("Bug reports and anything with an image are always sent privately. Only you and the developer can see them.")
            }
            else if isPrivate {

                Text("Only you and the developer can see this. It won't appear on the public board and can't be voted on.")
            }
            else {

                Text("Public feedback is visible to everyone using the app.")
            }
        }
    }

    /// Private-only mode: nothing to choose, so a plain statement instead of the toggle.
    @ViewBuilder private var privateOnlyNotice: some View {

        Section {

            Label("Sent privately to the developer", systemImage: "lock")

        } footer: { Text("Only you and the developer can see your feedback.") }
    }

    // MARK: - Search before submit

    /// **Never blocks submission.** Titles overlap innocently, and blocking on a near-match would lose
    /// real reports. This is a nudge with a vote button attached, nothing more.
    @ViewBuilder private var searchResults: some View {

        Section {

            ForEach(matches) { match in

                HStack(alignment: .firstTextBaseline) {

                    VStack(alignment: .leading, spacing: 4) {

                        Text(match.title)
                            .font(.subheadline)
                            .lineLimit(2)

                        // "Fixed in 2.1" is the single most useful thing to tell someone who is about
                        // to file a duplicate, so completed requests are included and flagged.
                        if match.status == .complete {

                            ResolvedVersionBadge(version: match.resolvedInVersion)
                        }
                        else if match.status != .open {

                            StatusBadge(status: match.status)
                        }
                    }

                    Spacer(minLength: 8)

                    VoteButton(count: store.votes.tally(for: match.id),
                               hasVoted: store.votes.hasVoted(on: match.id),
                               isBusy: false,
                               isEnabled: store.canWrite,
                               action: { voteFromSearch(match) })
                }
            }

        } header: { Text("Already reported?") }
          footer: { Text("Vote for an existing one instead, or carry on and submit yours.") }
    }

    private func scheduleSearch(for text: String) {

        searchTask?.cancel()

        // Private-only mode has no public requests to find, and must not query them.
        guard store.hasPublicBoard else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= Self.searchMinimumLength else {

            matches = []
            lastSearchedText = ""

            return
        }

        // Skip if the text has not actually changed since the last search.
        guard trimmed != lastSearchedText else { return }

        searchTask = Task {

            try? await Task.sleep(for: Self.searchDebounce)

            guard !Task.isCancelled else { return }

            let results = await store.requests.search(trimmed)

            guard !Task.isCancelled else { return }

            lastSearchedText = trimmed
            matches = results
        }
    }

    private func voteFromSearch(_ match: FeedbackRequest) {

        Task {

            do {

                try await store.votes.vote(on: match.id)

                votedFromSearch = match
            }
            catch {

                self.error = CloudKitErrorHandler.classify(error)
            }
        }
    }

    // MARK: - Submit

    private func submit() {

        // The button is disabled while a save is in flight. That is the whole of the double-tap
        // defence, and it is the only submission throttle here - a client-side cooldown is bypassable
        // and so protects nothing.
        guard canSubmit else { return }

        isSubmitting = true
        error = nil

        // Snapshot everything the save depends on now. The form stays editable while CloudKit is
        // pending, and the route must not change underneath it.
        let sendPrivately = isPrivate
        let kind = type
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body_.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = imageData
        let attachedFiles = sendPrivately ? files : []
        let attachedMetadata = includeMetadata ? metadata : [:]

        Task {

            do {

                if sendPrivately {

                    _ = try await store.privateReports.submit(title: trimmedTitle,
                                                              body: trimmedBody,
                                                              kind: kind,
                                                              imageData: images,
                                                              files: attachedFiles,
                                                              metadata: attachedMetadata)

                    // Uploaded; the temporary copies have done their job.
                    attachedFiles.forEach { $0.discard() }
                    files = []
                }
                else {

                    _ = try await store.submit(title: trimmedTitle,
                                               body: trimmedBody,
                                               type: kind,
                                               imageData: images,
                                               metadata: attachedMetadata)
                }

                submittedPrivately = sendPrivately
                showSuccess = true
            }
            catch {

                self.error = error as? FeedbackError ?? CloudKitErrorHandler.classify(error)
            }

            isSubmitting = false
        }
    }
}
