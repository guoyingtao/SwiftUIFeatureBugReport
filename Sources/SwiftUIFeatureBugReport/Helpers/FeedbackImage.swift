//
//  FeedbackImage.swift
//  SwiftUIFeatureBugReport
//

import CloudKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Image handling for attachments (§9.6).
///
/// Everything here goes through ImageIO rather than UIKit/AppKit so both platforms take the same
/// path - the only thing that genuinely differs between them is where the user picks the file from.
enum FeedbackImage {

    /// Long edge, in pixels, after downscaling. Comfortably enough to read a screenshot, small enough
    /// that a public container does not fill up with 12-megapixel uploads.
    static let maximumDimension = 1600

    static let compressionQuality = 0.7

    /// Re-encodes and downscales before upload.
    ///
    /// Re-encoding is what strips EXIF - including GPS, should a photo rather than a screenshot ever
    /// get through - and it bounds the payload at the same time. Returns a file URL because that is
    /// what `CKAsset` takes.
    static func prepareForUpload(_ data: Data) throws -> URL {

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {

            throw FeedbackError.imageEncodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {

            throw FeedbackError.imageEncodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {

            throw FeedbackError.imageEncodingFailed
        }

        // Only the pixels are copied across - no metadata dictionary is carried over from the source.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { throw FeedbackError.imageEncodingFailed }

        return url
    }

    /// Prepares a batch, stopping at `FeedbackRequest.maximumImages`.
    static func prepareForUpload(_ items: [Data]) throws -> [URL] {

        try items.prefix(FeedbackRequest.maximumImages).map { try prepareForUpload($0) }
    }

    /// `CKAsset.fileURL` points at a temporary file valid only for the lifetime of the operation that
    /// produced it. **Copy it out immediately** - reading it later gives intermittent nil images that
    /// are miserable to debug because they work every time you step through them.
    static func copyOut(_ asset: CKAsset) -> URL? {

        guard let source = asset.fileURL else { return nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-asset-\(UUID().uuidString)")
            .appendingPathExtension(source.pathExtension.isEmpty ? "jpg" : source.pathExtension)

        do {

            try FileManager.default.copyItem(at: source, to: destination)

            return destination
        }
        catch {

            return nil
        }
    }

    static func copyOut(_ assets: [CKAsset]) -> [URL] { assets.compactMap { copyOut($0) } }

    /// Bridges a file URL onto a SwiftUI `Image` without either platform's picker types leaking into
    /// call sites. Decoded through ImageIO at no more than `maxPixelSize` on the long edge, so an
    /// oversized attachment - written by an older build or another client - cannot balloon memory.
    @MainActor static func image(at url: URL, maxPixelSize: Int) -> Image? {

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        return image(from: source, maxPixelSize: maxPixelSize)
    }

    @MainActor static func thumbnail(from data: Data, maxPixelSize: Int) -> Image? {

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        return image(from: source, maxPixelSize: maxPixelSize)
    }

    @MainActor private static func image(from source: CGImageSource, maxPixelSize: Int) -> Image? {

        guard let cgImage = downsampled(source, maxPixelSize: maxPixelSize) else { return nil }

        // Not `decorative`: call sites attach their own accessibility labels.
        return Image(cgImage, scale: 1, label: Text("Image", bundle: .feedbackResources))
    }

    /// The decode itself, separate so it is unit tested.
    static func downsampled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {

        guard CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
