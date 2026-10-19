//
//  FeedbackEnums.swift
//  SwiftUIFeatureBugReport
//

import SwiftUI

/// Every enum here is `String`-backed with an **explicit** `init?(rawValue:)` that falls back to the
/// safe default instead of returning `nil`. A newer client writing a value this build has never heard
/// of must degrade, never crash or vanish from the list.

public enum FeedbackType: String, CaseIterable, Sendable, Hashable {

    case bug
    case feature

    public init?(rawValue: String) {

        switch rawValue {

        case "feature": self = .feature
        default: self = .bug
        }
    }

    public var localised: String {

        switch self {

        case .bug: return loc("Bug")
        case .feature: return loc("Feature")
        }
    }

    public var symbolName: String {

        switch self {

        case .bug: return "ladybug"
        case .feature: return "lightbulb"
        }
    }
}


public enum RequestStatus: String, CaseIterable, Sendable, Hashable {

    case open
    case inProgress
    case updatePending
    case complete

    public init?(rawValue: String) {

        switch rawValue {

        case "inProgress": self = .inProgress
        case "updatePending": self = .updatePending
        case "complete": self = .complete
        default: self = .open
        }
    }

    public var localised: String {

        switch self {

        case .open: return loc("Open")
        case .inProgress: return loc("In Progress")
        case .updatePending: return loc("Update Pending")
        case .complete: return loc("Complete")
        }
    }

    public var symbolName: String {

        switch self {

        case .open: return "circle"
        case .inProgress: return "hammer"
        case .updatePending: return "arrow.down.circle"
        case .complete: return "checkmark.circle.fill"
        }
    }

    public var tint: Color {

        switch self {

        case .open: return .secondary
        case .inProgress: return .orange
        case .updatePending: return .blue
        case .complete: return .green
        }
    }
}


public enum ModerationState: String, CaseIterable, Sendable, Hashable {

    /// The default. Auto-hides once the report count reaches the configured threshold.
    case visible

    /// A developer looked at the reports and cleared them. Report counts are ignored from here on,
    /// which is what stops a cleared request silently re-hiding itself.
    case approved

    /// Hidden from everyone but the developer.
    case hidden

    public init?(rawValue: String) {

        switch rawValue {

        case "approved": self = .approved
        case "hidden": self = .hidden
        default: self = .visible
        }
    }
}


/// Gates **display, not access.** CloudKit has no per-field permissions, so anyone who can query the
/// record can fetch its asset whatever this says. Rejecting an image therefore also nils the asset -
/// see `ModerationService.rejectImage(on:)`. This is a moderation queue, not a security control.
public enum ImageState: String, CaseIterable, Sendable, Hashable {

    case none
    case pending
    case approved
    case rejected

    public init?(rawValue: String) {

        switch rawValue {

        case "pending": self = .pending
        case "approved": self = .approved
        case "rejected": self = .rejected
        default: self = .none
        }
    }
}


public enum ActivityKind: String, CaseIterable, Sendable, Hashable {

    case status
    case comment
    case complete
    case imageApproved
    case imageRejected
    case shipped

    public init?(rawValue: String) {

        switch rawValue {

        case "comment": self = .comment
        case "complete": self = .complete
        case "imageApproved": self = .imageApproved
        case "imageRejected": self = .imageRejected
        case "shipped": self = .shipped
        default: self = .status
        }
    }

    public var symbolName: String {

        switch self {

        case .status: return "arrow.triangle.2.circlepath"
        case .comment: return "bubble.left"
        case .complete: return "checkmark.circle"
        case .imageApproved: return "photo"
        case .imageRejected: return "photo.badge.exclamationmark"
        case .shipped: return "shippingbox"
        }
    }

    /// The en-GB source string of this kind's push body (§8.1), which is also its catalogue key. The push
    /// sends `localizedText`, its translation; this stays as the stable, readable identifier.
    public var localizationKey: String {

        switch self {

        case .status: return "Status updated"
        case .comment: return "New reply"
        case .complete: return "Marked complete"
        case .imageApproved: return "Your image was approved"
        case .imageRejected: return "Your image was removed"
        case .shipped: return "Shipped"
        }
    }

    /// `localizationKey`, translated by the package's own catalogue. This is what the activity push now
    /// carries as its body: a localization key resolves against the host app's bundle, which does not
    /// have the package's translations. Fixed when the subscription is saved, in the language of the
    /// device that saved it - the recipient's own.
    public var localizedText: String {

        switch self {

        case .status: return loc("Status updated")
        case .comment: return loc("New reply")
        case .complete: return loc("Marked complete")
        case .imageApproved: return loc("Your image was approved")
        case .imageRejected: return loc("Your image was removed")
        case .shipped: return loc("Shipped")
        }
    }
}


public enum BoardSort: String, CaseIterable, Sendable, Hashable {

    case votes
    case mostRecent

    public var localised: String {

        switch self {

        case .votes: return loc("Votes")
        case .mostRecent: return loc("Most Recent")
        }
    }
}


public enum BoardFilter: String, CaseIterable, Sendable, Hashable {

    case all
    case bugs
    case features

    public var localised: String {

        switch self {

        case .all: return loc("All")
        case .bugs: return loc("Bugs")
        case .features: return loc("Features")
        }
    }

    func matches(_ type: FeedbackType) -> Bool {

        switch self {

        case .all: return true
        case .bugs: return type == .bug
        case .features: return type == .feature
        }
    }
}


/// Why something was reported.
///
/// A category rather than free text, so the portal's reported queue can be triaged at a glance and
/// no private-feeling prose is written to the world-readable `Report` record type.
public enum ReportCategory: String, CaseIterable, Sendable, Hashable {

    case spam
    case abusive
    case offTopic
    case duplicate
    case other

    public init?(rawValue: String) {

        switch rawValue {

        case "spam": self = .spam
        case "abusive": self = .abusive
        case "offTopic": self = .offTopic
        case "duplicate": self = .duplicate
        default: self = .other
        }
    }

    public var localised: String {

        switch self {

        case .spam: return loc("Spam")
        case .abusive: return loc("Abusive or offensive")
        case .offTopic: return loc("Off topic")
        case .duplicate: return loc("Duplicate")
        case .other: return loc("Something else")
        }
    }

    /// Plain-`String` form, for places that compose text rather than take a `LocalizedStringKey` -
    /// the portal's "reported as spam (3), off topic (1)" breakdown.
    public var displayName: String {

        switch self {

        case .spam: return String(localized: "Spam", bundle: .feedbackResources)
        case .abusive: return String(localized: "Abusive", bundle: .feedbackResources)
        case .offTopic: return String(localized: "Off topic", bundle: .feedbackResources)
        case .duplicate: return String(localized: "Duplicate", bundle: .feedbackResources)
        case .other: return String(localized: "Other", bundle: .feedbackResources)
        }
    }

    public var symbolName: String {

        switch self {

        case .spam: return "envelope.badge.shield.half.filled"
        case .abusive: return "exclamationmark.bubble"
        case .offTopic: return "arrow.uturn.left"
        case .duplicate: return "doc.on.doc"
        case .other: return "ellipsis.circle"
        }
    }
}
