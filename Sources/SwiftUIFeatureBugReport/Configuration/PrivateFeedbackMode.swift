//
//  PrivateFeedbackMode.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// How private, developer-only submissions are offered.
///
/// A private submission is saved as a `PrivateReport`, whose record type grants READ only to
/// `_creator` and `dev`. Unlike `ModerationState.hidden` or `ImageState.pending`, which only gate
/// display, this is enforced by CloudKit: other users cannot fetch or query the record at all.
public enum PrivateFeedbackMode: String, CaseIterable, Sendable, Hashable {

    /// No private option. The form looks exactly as it did before this existed.
    case disabled

    /// The form shows a "Private" toggle, off by default.
    case optional

    /// Bug reports and anything with an attachment are always private; feature requests without
    /// attachments stay public unless the user opts in. Screenshots and bug details are where
    /// personal data tends to turn up, so those never reach the public board.
    case bugsAndAttachments
}


/// The rules behind the form's private toggle, kept free of SwiftUI and CloudKit so they can be tested.
enum PrivateFeedbackPolicy {

    /// Whether the form shows the toggle at all.
    static func offersToggle(mode: PrivateFeedbackMode) -> Bool { mode != .disabled }

    /// Whether the submission must be private whatever the user chose. The toggle is shown on and
    /// disabled in this case, so the user can see why.
    static func isForced(mode: PrivateFeedbackMode, type: FeedbackType, hasAttachments: Bool) -> Bool {

        switch mode {

        case .disabled, .optional: return false
        case .bugsAndAttachments: return type == .bug || hasAttachments
        }
    }

    /// Whether this submission is saved as a `PrivateReport`.
    static func isPrivate(mode: PrivateFeedbackMode,
                          type: FeedbackType,
                          hasAttachments: Bool,
                          userChoice: Bool) -> Bool {

        guard offersToggle(mode: mode) else { return false }

        return isForced(mode: mode, type: type, hasAttachments: hasAttachments) || userChoice
    }

    /// Whether the image picker is offered.
    ///
    /// Private submissions may carry images even when public attachments are off - keeping
    /// screenshots out of the world-readable `Request` record is the main reason to go private.
    ///
    /// In `.bugsAndAttachments` mode a feature request with no images yet is not private, so with
    /// public attachments off the picker stays hidden until the user switches the toggle on.
    static func allowsImages(publicAttachmentsAllowed: Bool, isPrivate: Bool) -> Bool {

        publicAttachmentsAllowed || isPrivate
    }
}
