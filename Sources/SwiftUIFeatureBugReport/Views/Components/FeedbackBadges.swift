//
//  FeedbackBadges.swift
//  SwiftUIFeatureBugReport
//

import SwiftUI

struct TypeBadge: View {

    let type: FeedbackType

    var body: some View {

        Text(type.localised)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(type == .feature ? Color.blue : Color.red, in: Capsule())
            .foregroundStyle(.white)
    }
}


struct StatusBadge: View {

    let status: RequestStatus

    var body: some View {

        Label(status.localised, systemImage: status.symbolName)
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(status.tint)
    }
}


/// Marks a request that has been moderated off the board.
///
/// Only ever rendered for a developer - the visibility rule filters these out for everyone else, so
/// this is the marker that tells the person who hid it that it *is* hidden, and from whom.
struct HiddenBadge: View {

    var body: some View {

        Label(loc("Hidden"), systemImage: "eye.slash")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Hidden from users", bundle: .feedbackResources))
            .help(loc("Hidden from users. You can still see it because you are a developer."))
    }
}


struct LabelChip: View {

    let name: String

    var body: some View {

        Text(name)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(labelName: name), in: Capsule())
            .foregroundStyle(.white)
    }
}


/// The vote control.
///
/// Its accessibility label announces the count and whether this user has voted - VoiceOver reading
/// "button" over a bare arrow tells you nothing about either.
struct VoteButton: View {

    let count: Int
    let hasVoted: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {

        Button(action: action) {

            HStack(spacing: 4) {

                if isBusy {

                    ProgressView()
                        .controlSize(.small)
                }
                else {

                    Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                }

                Text(count.formatted(.number))
            }
            .font(.caption)
            .foregroundStyle(hasVoted ? Color.green : Color.accentColor)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        // Tappable while voted: the button toggles, so a mis-tap or a change of mind is recoverable.
        .disabled(isBusy || !isEnabled)
        .accessibilityLabel(hasVoted
                            ? Text("Voted. \(count) votes", bundle: .feedbackResources)
                            : Text("Vote. \(count) votes", bundle: .feedbackResources))
        .accessibilityHint(hasVoted ? Text("Withdraws your vote", bundle: .feedbackResources) : Text("Adds your vote", bundle: .feedbackResources))
        .accessibilityAddTraits(hasVoted ? [.isSelected] : [])
    }
}


/// "Fixed in 2.1" - the single most useful thing to tell someone looking at a completed request,
/// and the line that stops "then why is it still broken for me?" arriving as a support message.
///
/// Falls back to a plain "Fixed" when the developer has not recorded a version.
struct ResolvedVersionBadge: View {

    let version: String

    var body: some View {

        Group {

            if version.isEmpty { Label(loc("Fixed"), systemImage: "checkmark.circle.fill") }
            else { Label(loc("Fixed in \(version)"), systemImage: "checkmark.circle.fill") }
        }
        .font(.caption2)
        .foregroundStyle(.green)
    }
}


/// States the moderation situation at the top of a request in the portal.
///
/// Without it, hidden and auto-hidden requests look exactly like visible ones once you are inside
/// them - you can reply, set a status and announce a fix on something no user can see. The auto-hidden
/// case matters most: `moderation` is still `visible`, so nothing on the record says it is hidden;
/// only the report count crossing the threshold does, and that is computed client-side.
struct ModerationBanner: View {

    let moderation: ModerationState
    let reportCount: Int
    let threshold: Int

    private var state: (title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, tint: Color)? {

        switch moderation {

        case .hidden:
            return ("Hidden from everyone",
                    "No user can see this request. Unhide it from the menu to bring it back.",
                    "eye.slash.fill", .red)

        case .visible where reportCount >= threshold:
            return ("Automatically hidden",
                    "\(reportCount) reports reached the threshold of \(threshold), so users can no longer see this. Clear reports to restore it.",
                    "exclamationmark.triangle.fill", .orange)

        case .approved:
            return ("Reports cleared",
                    "Visible to everyone. Further reports will not hide it automatically.",
                    "checkmark.shield.fill", .green)

        default:
            return nil
        }
    }

    var body: some View {

        if let state {

            HStack(alignment: .firstTextBaseline, spacing: 12) {

                Image(systemName: state.symbol)
                    .foregroundStyle(state.tint)

                VStack(alignment: .leading, spacing: 2) {

                    Text(state.title, bundle: .feedbackResources)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.tint)

                    Text(state.detail, bundle: .feedbackResources)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}


/// Which app a record came from, in a container shared by several apps. Shown in the developer's
/// views only - users only ever see their own app's records.
struct AppBadge: View {

    let appID: String?

    var body: some View {

        if let appID {

            Text(verbatim: appID)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel(Text("App: \(appID)", bundle: .feedbackResources))
        }
    }
}


/// The developer's app filter. Hidden unless the loaded records span more than one app, so a single-app
/// container never sees it.
struct AppFilterPicker: View {

    @Binding var selection: AppFilter

    let appIDs: [String?]

    /// Whether the picker renders anything. Shown when there is more than one app to choose between
    /// (`choices` always includes `.all`), or a non-default selection is in effect so it can be cleared.
    /// Callers that wrap the picker (a `ToolbarItem`) use this to avoid an empty item.
    static func isVisible(selection: AppFilter, appIDs: [String?]) -> Bool {

        AppFilter.choices(for: appIDs).count > 2 || selection != .all
    }

    var body: some View {

        let choices = AppFilter.choices(for: appIDs)

        if Self.isVisible(selection: selection, appIDs: appIDs) {

            Picker(loc("App"), selection: $selection) {

                ForEach(choices, id: \.self) { choice in

                    switch choice {

                    case .all: Text("All apps", bundle: .feedbackResources).tag(choice)
                    case .app(let appID): Text(verbatim: appID).tag(choice)
                    case .unscoped: Text("No app", bundle: .feedbackResources).tag(choice)
                    }
                }
            }
            .labelsHidden()
            .accessibilityLabel(Text("Filter by app", bundle: .feedbackResources))
            .help(loc("Filter by app"))
#if os(macOS)
            .fixedSize()
#endif
        }
    }
}


/// A symbol with a small count badge on its corner - the portal entry's pending figure. Nothing is
/// drawn over the symbol at zero. Capped at "99+" so a backlog never outgrows the icon.
///
/// The count is decoration: callers give the control its own accessibility label with the number in it.
struct BadgedSymbol: View {

    let systemName: String
    let count: Int

    var body: some View {

        Image(systemName: systemName)
            .overlay(alignment: .topTrailing) {

                if count > 0 {

                    Text(verbatim: count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(.red, in: Capsule())
                        .fixedSize()
                        .offset(x: 8, y: -7)
                        .accessibilityHidden(true)
                }
            }
    }
}
