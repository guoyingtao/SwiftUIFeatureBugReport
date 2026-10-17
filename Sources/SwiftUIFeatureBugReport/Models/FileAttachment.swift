//
//  FileAttachment.swift
//  SwiftUIFeatureBugReport
//

import Foundation
import UniformTypeIdentifiers

/// The limits a file attachment is checked against - see `FeedbackConfiguration.fileAttachmentRules`.
///
/// Files ride on `PrivateReport` only. A public `Request` has no file field and `RequestService` takes
/// none, so a file can never reach the world-readable board.
public struct FileAttachmentRules: Sendable, Hashable {

    public let maxBytes: Int
    public let maxCount: Int
    public let allowedTypes: [UTType]

    public init(maxBytes: Int, maxCount: Int, allowedTypes: [UTType]) {

        self.maxBytes = maxBytes
        self.maxCount = maxCount
        self.allowedTypes = allowedTypes
    }

    /// Whether `type` conforms to one of `allowedTypes`. An unknown type is refused.
    public func accepts(_ type: UTType?) -> Bool {

        guard let type else { return false }

        return allowedTypes.contains { type.conforms(to: $0) }
    }

    /// The content type of a file name, from its extension. `nil` when there is none to go by.
    public static func contentType(forFileName name: String) -> UTType? {

        let ext = (name as NSString).pathExtension

        guard !ext.isEmpty else { return nil }

        return UTType(filenameExtension: ext)
    }

    /// Checks one more file against the rules, given how many are already attached.
    ///
    /// - Parameter contentType: The type the system reported for the file, or `nil` to infer it from
    ///   the name's extension.
    public func validate(name: String,
                         byteCount: Int,
                         contentType: UTType? = nil,
                         alreadyAttached: Int) -> FileAttachmentError? {

        guard alreadyAttached < maxCount else { return .tooMany(limit: maxCount) }

        guard accepts(contentType ?? Self.contentType(forFileName: name)) else { return .unsupportedType(name: name) }

        guard byteCount > 0 else { return .empty(name: name) }

        guard byteCount <= maxBytes else { return .tooLarge(name: name, bytes: byteCount, limit: maxBytes) }

        return nil
    }

    /// Re-checks a whole batch - the service does this before upload, whatever the form allowed.
    public func validate(_ files: [(name: String, byteCount: Int)]) -> FileAttachmentError? {

        guard files.count <= maxCount else { return .tooMany(limit: maxCount) }

        for (index, file) in files.enumerated() {

            if let error = validate(name: file.name, byteCount: file.byteCount, alreadyAttached: index) { return error }
        }

        return nil
    }
}


/// Why a file was refused. Every message is a localisable en-GB source string.
public enum FileAttachmentError: LocalizedError, Sendable, Hashable {

    case tooLarge(name: String, bytes: Int, limit: Int)
    case unsupportedType(name: String)
    case tooMany(limit: Int)
    case empty(name: String)
    case unreadable(name: String)

    /// File attachments are off, or private feedback is.
    case notAllowed

    /// The report says it has a file there, but CloudKit returned no asset for it.
    case missing(name: String)

    public var errorDescription: String? {

        switch self {

        case .tooLarge(let name, let bytes, let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return String(localized: "“\(name)” is \(size). Files can be up to \(maximum).")

        case .unsupportedType(let name):
            return String(localized: "“\(name)” isn't a type of file that can be attached.")

        case .tooMany(let limit):
            return String(localized: "You can attach up to \(limit) files.")

        case .empty(let name):
            return String(localized: "“\(name)” is empty.")

        case .unreadable(let name):
            return String(localized: "“\(name)” couldn't be read.")

        case .notAllowed:
            return String(localized: "Files can't be attached here.")

        case .missing(let name):
            return String(localized: "“\(name)” is no longer available.")
        }
    }
}


/// File names as stored in `PrivateReport.fileNames` and used for the local copy Quick Look opens.
///
/// The name is client-written, so it is sanitised both when stored and when read: a crafted record
/// could carry `../` or a path, and the reader uses the name to build a temporary file path.
public enum FileAttachmentName {

    /// Longest stored name, extension included.
    public static let maximumLength = 120

    public static func sanitized(_ raw: String, fallback: String = "Attachment") -> String {

        // Only the last path component; separators and control characters out.
        let lastComponent = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

        var cleaned = String(lastComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // No hidden files, no "." or "..".
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }

        guard !cleaned.isEmpty else { return fallback }

        guard cleaned.count > maximumLength else { return cleaned }

        // Keep the extension so the type still resolves - Quick Look and Books go by it.
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.count > 16 ? "" : "." + ext
        let stem = String(cleaned.dropLast(suffix.count).prefix(maximumLength - suffix.count))

        return stem + suffix
    }
}


/// A file picked in the form, already copied out of its security scope into a temporary location.
public struct PendingFileAttachment: Identifiable, Sendable, Hashable {

    public let id: UUID
    public let name: String
    public let byteCount: Int

    /// A private temporary copy, named `name`. Upload reads it from here.
    public let url: URL

    public init(id: UUID = UUID(), name: String, byteCount: Int, url: URL) {

        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.url = url
    }

    /// Copies a picked file into a fresh temporary directory under its sanitised name, checking it
    /// against `rules` first. Handles the importer's security scope itself.
    ///
    /// Synchronous file IO - call it off the main actor.
    public static func importFile(at source: URL,
                                  rules: FileAttachmentRules,
                                  alreadyAttached: Int) -> Result<PendingFileAttachment, FileAttachmentError> {

        let didStartAccess = source.startAccessingSecurityScopedResource()

        defer { if didStartAccess { source.stopAccessingSecurityScopedResource() } }

        let name = FileAttachmentName.sanitized(source.lastPathComponent)

        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])

        guard values?.isDirectory != true else { return .failure(.unsupportedType(name: name)) }

        let size = values?.fileSize
            ?? (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
            ?? 0

        if let error = rules.validate(name: name, byteCount: size, contentType: values?.contentType, alreadyAttached: alreadyAttached) {

            return .failure(error)
        }

        do {

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FeedbackFiles", isDirectory: true)
                .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = directory.appendingPathComponent(name)

            try FileManager.default.copyItem(at: source, to: destination)

            // Measured again on the copy: the reported size can be stale for a file still being written.
            let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? size

            if copiedSize > rules.maxBytes {

                try? FileManager.default.removeItem(at: directory)

                return .failure(.tooLarge(name: name, bytes: copiedSize, limit: rules.maxBytes))
            }

            return .success(PendingFileAttachment(name: name, byteCount: copiedSize, url: destination))
        }
        catch {

            return .failure(.unreadable(name: name))
        }
    }

    /// Removes the temporary copy and its directory.
    public func discard() {

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}


/// A file attached to a `PrivateReport`, as listed - name and size, no bytes.
///
/// The bytes are fetched only when the file is opened - see `PrivateReportService.downloadFile`.
public struct PrivateFile: Identifiable, Sendable, Hashable {

    /// Position in the report's `files` list - the asset this entry names.
    public let index: Int
    public let name: String

    /// `nil` when the report carries no size for it.
    public let byteCount: Int64?

    public var id: Int { index }

    /// The type implied by the name, for the row's icon.
    public var contentType: UTType? { FileAttachmentRules.contentType(forFileName: name) }

    public init(index: Int, name: String, byteCount: Int64?) {

        self.index = index
        self.name = name
        self.byteCount = byteCount
    }

    /// Pairs `fileNames` and `fileSizes` with the `files` list.
    ///
    /// The lists are client-written at creation and could disagree. The number of entries follows the
    /// asset count when it is known (`assetCount`), otherwise the name count; a missing name reads as
    /// "Attachment N", and every name is sanitised.
    static func list(names: [String], sizes: [Int64], assetCount: Int?) -> [PrivateFile] {

        let count = assetCount ?? names.count

        return (0..<max(0, count)).map { index in

            let fallback = "Attachment \(index + 1)"
            let name = index < names.count ? FileAttachmentName.sanitized(names[index], fallback: fallback) : fallback
            let size = index < sizes.count && sizes[index] >= 0 ? sizes[index] : nil

            return PrivateFile(index: index, name: name, byteCount: size)
        }
    }
}


extension FileAttachmentRules {

    /// The SF Symbol a file row shows for a type.
    public static func symbolName(for type: UTType?) -> String {

        guard let type else { return "doc" }

        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .epub) { return "book.closed" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .text) { return "doc.plaintext" }

        return "doc"
    }
}
