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

    /// Private-only: there is no public board at all. No public list, roadmap, voting, comments,
    /// search of public requests or Updates feed - every submission is a `PrivateReport`, and the
    /// board's main screen is the user's own private reports with a "New feedback" action. The form
    /// shows no public/private toggle. The developer portal shows the private queue only.
    ///
    /// For apps where feedback is personal by nature - a reader's library, a journal, anything whose
    /// bug reports are likely to carry the user's own content.
    case only

    /// Whether private reports exist in this mode at all - "My private reports", the portal's
    /// private queue, the `PrivateReport` record type.
    public var offersPrivateReports: Bool { self != .disabled }

    /// Whether the public board - requests, votes, comments, roadmap, Updates - is used.
    public var hasPublicBoard: Bool { self != .only }
}


/// The rules behind the form's private toggle, kept free of SwiftUI and CloudKit so they can be tested.
enum PrivateFeedbackPolicy {

    /// Whether the form shows the toggle at all.
    ///
    /// `.only` has nothing to choose between, so no toggle either.
    static func offersToggle(mode: PrivateFeedbackMode) -> Bool { mode == .optional || mode == .bugsAndAttachments }

    /// Whether the submission must be private whatever the user chose. The toggle is shown on and
    /// disabled in this case, so the user can see why.
    ///
    /// - Parameters:
    ///   - hasAttachments: Images are attached.
    ///   - hasFiles: Files are attached. Files are never public, in any mode, so one forces private.
    static func isForced(mode: PrivateFeedbackMode,
                         type: FeedbackType,
                         hasAttachments: Bool,
                         hasFiles: Bool = false) -> Bool {

        switch mode {

        case .disabled: return false
        case .optional: return hasFiles
        case .bugsAndAttachments: return type == .bug || hasAttachments || hasFiles
        case .only: return true
        }
    }

    /// Whether this submission is saved as a `PrivateReport`.
    static func isPrivate(mode: PrivateFeedbackMode,
                          type: FeedbackType,
                          hasAttachments: Bool,
                          hasFiles: Bool = false,
                          userChoice: Bool) -> Bool {

        guard mode.offersPrivateReports else { return false }

        return isForced(mode: mode, type: type, hasAttachments: hasAttachments, hasFiles: hasFiles)
            || (offersToggle(mode: mode) && userChoice)
    }

    /// Why the toggle is locked on, for its footer. `nil` when it is not forced.
    static func forcedReason(mode: PrivateFeedbackMode,
                             type: FeedbackType,
                             hasAttachments: Bool,
                             hasFiles: Bool) -> ForcedReason? {

        guard isForced(mode: mode, type: type, hasAttachments: hasAttachments, hasFiles: hasFiles) else { return nil }

        switch mode {

        case .disabled: return nil
        case .only: return .privateOnly
        case .optional: return .files
        case .bugsAndAttachments: return hasFiles && type != .bug && !hasAttachments ? .files : .bugsAndAttachments
        }
    }

    enum ForcedReason: Equatable {

        /// `.bugsAndAttachments`: a bug report, or images attached.
        case bugsAndAttachments

        /// A file is attached, and files are private-only.
        case files

        /// `.only`: everything is private.
        case privateOnly
    }

    /// Whether the "Attach file" control is offered: file attachments turned on and private reports
    /// available. Files only ever travel on a `PrivateReport`, so attaching one forces the submission
    /// private (`isForced`) rather than the control hiding until the user flips the toggle.
    static func allowsFiles(fileAttachmentsEnabled: Bool, mode: PrivateFeedbackMode) -> Bool {

        fileAttachmentsEnabled && mode.offersPrivateReports
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
