//
//  PrivateAttachmentRemoval.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// One attachment on a `PrivateReport` that the developer can remove - see
/// `PrivateReportService.removeAttachment(_:from:)`.
public enum PrivateAttachment: Sendable, Hashable {

    /// An entry in `files`, with `fileNames` and `fileSizes` at the same position.
    case file(PrivateFile)

    /// An entry in `images`. `count` is how many images the detail view showed, so a list that changed
    /// meanwhile - or an image that could not be copied out - is noticed instead of removing the wrong
    /// one.
    case image(index: Int, count: Int)
}


/// Why an attachment could not be removed. Nothing was saved in any of these cases.
public enum AttachmentRemovalError: LocalizedError, Sendable, Hashable {

    /// The parallel lists (`files`, `fileNames`, `fileSizes`) have different lengths, so a position
    /// does not name one attachment. Only a crafted record looks like this.
    case lengthMismatch(counts: [Int])

    /// There is no attachment at that position.
    case indexOutOfRange(index: Int, count: Int)

    /// The report's attachments changed since it was loaded.
    case changed

    /// The view's copy is out of date - reloading shows the attachments as they are now.
    public var isStale: Bool {

        switch self {

        case .lengthMismatch: return false
        case .indexOutOfRange, .changed: return true
        }
    }

    public var errorDescription: String? {

        switch self {

        case .lengthMismatch:
            return String(localized: "This report's attachment lists don't match, so a single attachment can't be removed. Delete the whole report instead.", bundle: .feedbackResources)

        case .indexOutOfRange, .changed:
            return String(localized: "The attachments on this report have changed. Reload it and try again.", bundle: .feedbackResources)
        }
    }
}


/// Pure list surgery for `removeAttachment`. Every list loses the same position, so the remaining
/// entries stay paired.
enum ParallelLists {

    /// Throws unless every count is equal and `index` is within it.
    static func validate(index: Int, counts: [Int]) throws {

        guard let first = counts.first else { return }

        guard counts.allSatisfy({ $0 == first }) else { throw AttachmentRemovalError.lengthMismatch(counts: counts) }

        guard index >= 0, index < first else { throw AttachmentRemovalError.indexOutOfRange(index: index, count: first) }
    }

    /// One list, whose current length must be `expectedCount`.
    static func removing<A>(at index: Int, from list: [A], expectedCount: Int) throws -> [A] {

        guard list.count == expectedCount else { throw AttachmentRemovalError.changed }

        try validate(index: index, counts: [list.count])

        var result = list
        result.remove(at: index)

        return result
    }

    /// Three lists of the same length, each without `index`.
    static func removing<A, B, C>(at index: Int, from a: [A], _ b: [B], _ c: [C]) throws -> ([A], [B], [C]) {

        try validate(index: index, counts: [a.count, b.count, c.count])

        var a = a, b = b, c = c

        a.remove(at: index)
        b.remove(at: index)
        c.remove(at: index)

        return (a, b, c)
    }

    /// Whether the stored name and size at `file.index` are still the ones the developer saw - the
    /// same sanitising and fallback as `PrivateFile.list`. Positions are checked by `validate`.
    static func matches(_ file: PrivateFile, names: [String], sizes: [Int64]) -> Bool {

        guard file.index >= 0, file.index < names.count, file.index < sizes.count else { return false }

        let name = FileAttachmentName.sanitized(names[file.index], fallback: "Attachment \(file.index + 1)")
        let size = sizes[file.index] >= 0 ? sizes[file.index] : nil

        return name == file.name && size == file.byteCount
    }
}
