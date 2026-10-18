//
//  MyDataView.swift
//  SwiftUIFeatureBugReport
//

import SwiftUI

/// Reached from the board's overflow menu (§9.4). Not on the main screen, not buried three levels
/// down - somewhere a user looking for it will actually find it.
/// The body of `MyDataView`, built only once the gate has a prepared store.
struct MyDataViewContent: View {

    @State private var store: FeedbackStore
    @State private var showingDeleteConfirmation = false

    private let embedsNavigationStack: Bool

    init(store: FeedbackStore, embedsNavigationStack: Bool = true) {

        self.store = store
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {

        if embedsNavigationStack {

            NavigationStack { myData }
        }
        else {

            myData
        }
    }

    @ViewBuilder private var myData: some View {

        Form {

            if !store.canWrite {

                Section { ReadOnlyNotice() }
            }
            else {

                Section {

                    if store.accountData.isLoading {

                        HStack { ProgressView().controlSize(.small); Text("Counting…") }
                    }
                    else {

                        LabeledContent("Requests", value: store.accountData.counts.requests.formatted(.number))
                        LabeledContent("Votes", value: store.accountData.counts.votes.formatted(.number))
                            .foregroundStyle(.secondary)
                        LabeledContent("Replies", value: store.accountData.counts.comments.formatted(.number))
                        LabeledContent("Reports", value: store.accountData.counts.reports.formatted(.number))

                        // Shown whenever there are any, even with private feedback since turned off -
                        // deletion still covers them below.
                        if showsPrivateReports {

                            LabeledContent("Private reports", value: store.accountData.counts.privateReports.formatted(.number))

                            if store.accountData.counts.privateDeletionRequested {

                                Label("Deletion requested. The developer will delete your private reports.", systemImage: "clock")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                } header: { Text("Your activity") }
                  footer: {

                      VStack(alignment: .leading, spacing: 6) {

                          if isAppScoped {

                              Text("These counts cover this app only. Feedback you left in other apps is managed, and deleted, from those apps.")
                          }

                          Text("Tied to your iCloud account. No email address, no sign-up, no account was created for you.")
                      }
                  }

                Section {

                    Button(role: .destructive, action: { showingDeleteConfirmation = true },
                           label: { Label("Delete my requests, replies and reports", systemImage: "trash") })
                        .disabled(store.accountData.isDeleting || store.accountData.counts.isEmpty)

                    if store.accountData.isDeleting {

                        HStack { ProgressView().controlSize(.small); Text("Deleting…") }
                    }

                } footer: {

                    VStack(alignment: .leading, spacing: 6) {

                        if isAppScoped {

                            Text("Only your data in this app is deleted. To delete what you posted in other apps, use “My requests” in each of those apps.")
                        }

                        Text("Votes you cast on other people's requests aren't included. A vote carries no text, and removing them would quietly change someone else's total. Withdraw a vote from the request itself.")

                        if showsPrivateReports {

                            Text("Private reports can only be deleted by the developer. Deleting your data sends them a deletion request, and your private reports stay until they process it.")
                        }
                    }
                }

                if !store.reports.blockedAuthors.isEmpty { blockedSection }
            }

            if let error = store.accountData.error {

                Section { FeedbackErrorBanner(error: error, retry: nil) }
            }
        }
        .formStyle(.grouped)
        .ownedNavigationTitle(store.hasPublicBoard ? "My requests" : "My data", ownsStack: embedsNavigationStack)
        .inlineNavigationTitle()
        .task {

            await store.start()
            await store.accountData.loadCounts()
        }

        .confirmationDialog(isAppScoped ? LocalizedStringKey("Delete everything you've posted in this app?") : LocalizedStringKey("Delete everything you've posted?"),
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {

            Button("Delete everything", role: .destructive) {

                Task { await store.deleteMyData() }
            }

            Button("Cancel", role: .cancel) { }

        } message: {

            // Stated plainly rather than buried, in both directions: what goes, and what stays.
            // Deleting a request really does take other people's votes and replies on it with it, and
            // someone about to do that deserves to know before rather than after.
            if isAppScoped {

                if showsPrivateReports {

                    Text("This permanently deletes your requests, replies and reports in this app. Any votes and replies other people left on your requests go with them. Votes you cast on other people's requests stay, so their totals aren't changed. Withdraw those individually if you want them gone. Your private reports from this app are sent to the developer for deletion. Your data in other apps isn't affected; delete it from those apps. This can't be undone.")
                }
                else {

                    Text("This permanently deletes your requests, replies and reports in this app. Any votes and replies other people left on your requests go with them. Votes you cast on other people's requests stay, so their totals aren't changed. Withdraw those individually if you want them gone. Your data in other apps isn't affected; delete it from those apps. This can't be undone.")
                }
            }
            else if showsPrivateReports {

                Text("This permanently deletes your requests, replies and reports. Any votes and replies other people left on your requests go with them. Votes you cast on other people's requests stay, so their totals aren't changed. Withdraw those individually if you want them gone. Your private reports are sent to the developer for deletion. This can't be undone.")
            }
            else {

                Text("This permanently deletes your requests, replies and reports. Any votes and replies other people left on your requests go with them. Votes you cast on other people's requests stay, so their totals aren't changed. Withdraw those individually if you want them gone. This can't be undone.")
            }
        }
    }

    /// `appID` is set, so counts and deletion cover this app only.
    private var isAppScoped: Bool { store.accountData.isAppScoped }

    private var showsPrivateReports: Bool {

        store.configuration.privateFeedback.offersPrivateReports || store.accountData.counts.privateReports > 0
    }

    @ViewBuilder private var blockedSection: some View {

        Section {

            ForEach(Array(store.reports.blockedAuthors).sorted(), id: \.self) { author in

                HStack {

                    Text(author)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Unblock") { store.reports.unblock(author: author) }
                        .font(.caption)
                }
            }

        } header: { Text("Blocked authors") }
          footer: { Text("Kept on this device only.") }
    }
}


/// A public entry point. Its initialisers only store their arguments, so constructing it - which
/// SwiftUI does eagerly for `NavigationLink(destination:)` - does no work at all.
public struct MyDataView: View {

    private let source: FeedbackStoreSource
    private let embedsNavigationStack: Bool

    /// Stores its arguments and nothing else. The store, and with it the `CKContainer`, is created
    /// only when this view is displayed - see `FeedbackStoreGate`.
    public init(configuration: FeedbackConfiguration, embedsNavigationStack: Bool = true) {

        self.source = .configuration(configuration)
        self.embedsNavigationStack = embedsNavigationStack
    }

    public init(store: FeedbackStore, embedsNavigationStack: Bool = true) {

        self.source = .store(store)
        self.embedsNavigationStack = embedsNavigationStack
    }

    public var body: some View {

        FeedbackStoreGate(source: source) { store in MyDataViewContent(store: store, embedsNavigationStack: embedsNavigationStack) }
    }
}
