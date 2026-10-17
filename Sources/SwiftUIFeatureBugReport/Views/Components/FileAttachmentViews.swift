//
//  FileAttachmentViews.swift
//  SwiftUIFeatureBugReport
//

import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The form's "Attach file" control: the attached files with name, size and a remove button, then the
/// picker. `.fileImporter` on both platforms - Files on iOS, an open panel on the Mac.
///
/// Picked files arrive security-scoped. Each is opened, checked against `rules`, copied into a
/// private temporary directory under its sanitised name and released again - see
/// `PendingFileAttachment.importFile`. The copy is what gets uploaded.
struct FileAttachmentPicker: View {

    @Binding var files: [PendingFileAttachment]

    let rules: FileAttachmentRules

    /// True while picked files are still being copied in. The form must not submit meanwhile: the
    /// files are not in `files` yet, so the report would go without them - and still say "sent".
    @Binding var isCopying: Bool

    /// The last refusal, shown under the list. Cleared by the next successful pick or removal.
    @State private var error: FileAttachmentError?
    @State private var isImporting = false

    private var remaining: Int { max(0, rules.maxCount - files.count) }

    var body: some View {

        ForEach(files) { file in

            HStack(spacing: 10) {

                FileIcon(type: FileAttachmentRules.contentType(forFileName: file.name))

                VStack(alignment: .leading, spacing: 2) {

                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(action: { remove(file) },
                       label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical) })
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(file.name)"))
            }
            .accessibilityElement(children: .combine)
        }

        if remaining > 0 {

            Button(action: { isImporting = true }) {

                HStack {

                    Label(files.isEmpty ? "Attach file" : "Attach another file", systemImage: "paperclip")

                    if isCopying {

                        Spacer()

                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isCopying)
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: rules.allowedTypes,
                          allowsMultipleSelection: remaining > 1) { result in

                switch result {

                case .success(let urls): importFiles(urls)
                case .failure: break
                }
            }
        }
        else {

            Text("Maximum of \(rules.maxCount) files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error, let message = error.errorDescription {

            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func remove(_ file: PendingFileAttachment) {

        file.discard()
        files.removeAll { $0.id == file.id }
        error = nil
    }

    /// Copies off the main actor - a 20 MB file is a noticeable stall otherwise.
    private func importFiles(_ urls: [URL]) {

        let rules = self.rules
        let alreadyAttached = files.count

        isCopying = true

        Task {

            let outcome = await Task.detached(priority: .userInitiated) { () -> ([PendingFileAttachment], FileAttachmentError?) in

                var imported: [PendingFileAttachment] = []
                var firstError: FileAttachmentError?

                for url in urls {

                    switch PendingFileAttachment.importFile(at: url, rules: rules, alreadyAttached: alreadyAttached + imported.count) {

                    case .success(let file): imported.append(file)
                    case .failure(let refusal): if firstError == nil { firstError = refusal }
                    }
                }

                return (imported, firstError)
            }.value

            // The user may have removed some while copying; never exceed the limit.
            let room = max(0, rules.maxCount - files.count)

            files.append(contentsOf: outcome.0.prefix(room))
            outcome.0.dropFirst(room).forEach { $0.discard() }

            error = outcome.1 ?? (outcome.0.count > room ? .tooMany(limit: rules.maxCount) : nil)
            isCopying = false
        }
    }
}


/// Files attached to a private report, in its detail view - for the submitter and the developer alike.
///
/// Tapping a row downloads that one file (`PrivateReportService.downloadFile`), copies it under its
/// original name and opens it in Quick Look. Once downloaded, a share button exports it - to Files,
/// Books or anywhere else.
///
/// With `onDelete` - the developer portal only - each row also gets a trash button, a swipe action and
/// a context menu item. The caller confirms before anything is removed.
struct PrivateFileList: View {

    let store: FeedbackStore
    let report: PrivateReport

    var onDelete: ((PrivateFile) -> Void)? = nil

    @State private var downloaded: [Int: URL] = [:]
    @State private var downloading: Set<Int> = []
    @State private var failures: [Int: String] = [:]
    @State private var previewURL: URL?

    var body: some View {

        Section {

            ForEach(report.files) { file in row(for: file) }

        } header: { Text("Files") }
          .quickLookPreview($previewURL)
          // Positions shift when a file is removed, so per-position state would point at the wrong file.
          .onChange(of: report.files) { _, _ in

              downloaded = [:]
              failures = [:]
          }
    }

    @ViewBuilder private func row(for file: PrivateFile) -> some View {

        HStack(spacing: 10) {

            Button(action: { open(file) }) {

                HStack(spacing: 10) {

                    FileIcon(type: file.contentType)

                    VStack(alignment: .leading, spacing: 2) {

                        Text(file.name)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)

                        if let failure = failures[file.index] {

                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        else if let size = file.byteCount {

                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if downloading.contains(file.index) {

                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(downloading.contains(file.index))
            .accessibilityHint(Text("Opens a preview"))

            if let url = downloaded[file.index] {

                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Share \(file.name)"))
            }

            if let onDelete {

                Button(role: .destructive, action: { onDelete(file) }) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("Remove \(file.name)"))
            }
        }
        .modifier(PrivateFileDeleteActions(file: file, onDelete: onDelete))
    }

    private func open(_ file: PrivateFile) {

        if let url = downloaded[file.index], FileManager.default.fileExists(atPath: url.path) {

            previewURL = url
            return
        }

        downloading.insert(file.index)
        failures[file.index] = nil

        Task {

            do {

                let url = try await store.privateReports.downloadFile(file, of: report)

                downloaded[file.index] = url
                previewURL = url
            }
            catch {

                failures[file.index] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            downloading.remove(file.index)
        }
    }
}


/// The swipe action and context menu item of a removable file row. Nothing without `onDelete`.
private struct PrivateFileDeleteActions: ViewModifier {

    let file: PrivateFile
    let onDelete: ((PrivateFile) -> Void)?

    @ViewBuilder func body(content: Content) -> some View {

        if let onDelete {

            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {

                    Button(role: .destructive, action: { onDelete(file) }) { Label("Remove", systemImage: "trash") }
                }
                .contextMenu {

                    Button(role: .destructive, action: { onDelete(file) }) { Label("Remove file", systemImage: "trash") }
                }
        }
        else {

            content
        }
    }
}


/// A file type's symbol, in a fixed-width frame so names line up.
struct FileIcon: View {

    let type: UTType?

    var body: some View {

        Image(systemName: FileAttachmentRules.symbolName(for: type))
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}
