//
//  FeedbackError.swift
//  SwiftUIFeatureBugReport
//

import Foundation

public enum FeedbackError: LocalizedError, Sendable {

    /// No iCloud account. Read-only, not a failure - see `FeedbackContainer.identityState`.
    case notSignedIn

    /// Identity has not resolved yet. Views should wait rather than render "not mine, not voted".
    case identityUnavailable

    case metadataTooLarge(bytes: Int, limit: Int)

    /// The misconfiguration case. Almost always a skipped setup step rather than a package bug.
    case developerRoleNotConfigured

    case rateLimited(retryAfter: TimeInterval)

    case networkUnavailable

    /// The record is gone - usually because a developer deleted it. Handled silently at call sites.
    case recordMissing

    /// The record *type* does not exist in this environment. Almost always a schema that was imported
    /// into Development but never deployed to Production.
    case schemaNotDeployed

    case imageEncodingFailed

    /// A developer-only action was attempted by someone who is not listed as a developer. A client-side
    /// check only - the `dev` security role is what CloudKit actually enforces.
    case developerOnly

    case underlying(String)

    public var errorDescription: String? {

        switch self {

        case .notSignedIn:
            return String(localized: "Sign in to iCloud to post, vote or comment. You can still read the board.", bundle: .feedbackResources)

        case .identityUnavailable:
            return String(localized: "Still checking your iCloud account. Try again in a moment.", bundle: .feedbackResources)

        case .metadataTooLarge(let bytes, let limit):
            return String(localized: "The attached metadata is \(bytes) bytes, over the \(limit) byte limit.", bundle: .feedbackResources)

        case .developerRoleNotConfigured:
            return String(localized: "CloudKit developer role not configured. See README setup step 4.", bundle: .feedbackResources)

        case .rateLimited(let retryAfter):
            let seconds = Int((CloudKitErrorHandler.sanitizedDelay(retryAfter) ?? 30).rounded(.up))

            return String(localized: "Too many requests. Try again in \(seconds) seconds.", bundle: .feedbackResources)

        case .networkUnavailable:
            return String(localized: "No network connection.", bundle: .feedbackResources)

        case .recordMissing:
            return String(localized: "That item no longer exists.", bundle: .feedbackResources)

        case .schemaNotDeployed:
            return String(localized: "This app's feedback schema isn't set up in this CloudKit environment. If this is a production build, deploy the schema to Production in the CloudKit Dashboard.", bundle: .feedbackResources)

        case .imageEncodingFailed:
            return String(localized: "That image could not be prepared for upload.", bundle: .feedbackResources)

        case .developerOnly:
            return String(localized: "Only the developer can do that.", bundle: .feedbackResources)

        case .underlying(let message):
            return message
        }
    }
}
