//
//  FeedbackStoreGate.swift
//  SwiftUIFeatureBugReport
//

import SwiftUI

/// Where a public entry view gets its store from.
enum FeedbackStoreSource {

    /// Build one - but only when the view's body is first evaluated, i.e. it is actually on screen.
    case configuration(FeedbackConfiguration)

    /// The host's shared store.
    case store(FeedbackStore)
}


/// Holds a lazily built store. A plain class, deliberately not observable: filling it in from `body`
/// must not invalidate the view being rendered.
@MainActor final class LazyFeedbackStore {

    private var store: FeedbackStore?

    func resolve(_ source: FeedbackStoreSource) -> FeedbackStore {

        switch source {

        case .store(let store):
            return store

        case .configuration(let configuration):
            if let store { return store }

            let created = FeedbackStore(configuration: configuration)

            store = created

            return created
        }
    }
}


/// Every public entry view's body runs through this.
///
/// The public view structs hold only their arguments. SwiftUI constructs those values eagerly - every
/// `NavigationLink(destination:)` on a settings screen builds its destination each time the screen
/// renders - so nothing may happen in their initialisers. The store is created here, from `body`,
/// which SwiftUI only evaluates for a view that is actually displayed; and `prepare()` decides,
/// before anything touches CloudKit, whether to show the content or an error state.
struct FeedbackStoreGate<Content: View>: View {

    let source: FeedbackStoreSource

    @ViewBuilder let content: (FeedbackStore) -> Content

    /// `@State` keeps one store for the lifetime of the displayed view, exactly as the previous
    /// `@State private var store` did. Its initial value is a tiny empty box.
    @State private var lazyStore = LazyFeedbackStore()

    var body: some View {

        let store = lazyStore.resolve(source)

        switch store.prepare() {

        case .available:
            content(store)

        case .unavailable(let reason):
            FeedbackUnavailableView(reason: reason)
        }
    }
}


/// Shown in place of any feedback screen when CloudKit cannot be used in this build.
struct FeedbackUnavailableView: View {

    let reason: FeedbackUnavailableReason

    var body: some View {

        ContentUnavailableView {

            Label("Feedback unavailable", systemImage: "exclamationmark.icloud")
        }
        description: {

            Text(reason.localizedDescription)
        }
    }
}
