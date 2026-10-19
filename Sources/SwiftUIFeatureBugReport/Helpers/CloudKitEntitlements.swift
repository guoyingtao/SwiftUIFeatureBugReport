//
//  CloudKitEntitlements.swift
//  SwiftUIFeatureBugReport
//

import Foundation

/// Why the feedback screens cannot use CloudKit in this build. Shown instead of the board.
public enum FeedbackUnavailableReason: Sendable, Equatable {

    /// `FeedbackConfiguration.containerIdentifier` is empty or does not start with `iCloud.`.
    case invalidContainerIdentifier(String)

    /// The app is not signed with `com.apple.developer.icloud-services` including `CloudKit`.
    case missingCloudKitEntitlement

    /// The app has CloudKit, but this container is not in `com.apple.developer.icloud-container-identifiers`.
    case containerNotInEntitlements(String)

    public var localizedDescription: String {

        switch self {

        case .invalidContainerIdentifier(let identifier):
            return String(localized: "Feedback is not set up correctly in this build: \"\(identifier)\" is not a valid iCloud container identifier.", bundle: .feedbackResources)

        case .missingCloudKitEntitlement:
            return String(localized: "Feedback is not available in this build: the app is not signed with the iCloud (CloudKit) capability.", bundle: .feedbackResources)

        case .containerNotInEntitlements(let identifier):
            return String(localized: "Feedback is not available in this build: the iCloud container \(identifier) is not in the app's entitlements.", bundle: .feedbackResources)
        }
    }
}


/// The iCloud entitlements the running executable was signed with.
///
/// `CKContainer(identifier:)` does not throw when they are missing: CloudKit logs "Significant issue at
/// CKContainer.m" and executes a `brk` trap, which no `do`/`catch` or Objective-C `@try` can intercept.
/// iOS has no public API to read your own entitlements (`SecTaskCopyValueForEntitlement` is macOS
/// only), so this reads them from the executable's code signature - the same blob the kernel and
/// CloudKit check - before any container is created.
///
/// The check only ever *blocks* on a definite answer. Anything it cannot read or parse is `nil`
/// ("unknown"), and the caller then creates the container as it always did.
struct CloudKitEntitlementFacts: Sendable, Equatable {

    static let servicesKey = "com.apple.developer.icloud-services"
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let developmentContainersKey = "com.apple.developer.icloud-container-development-container-identifiers"

    var services: [String]
    var containers: [String]

    /// No entitlements at all - a signature that carries no entitlements blob.
    static let empty = CloudKitEntitlementFacts(services: [], containers: [])

    /// Parses an XML or binary entitlements plist. `nil` when it is not a dictionary plist.
    init?(plist data: Data) {

        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }

        self.init(dictionary: dictionary)
    }

    init(dictionary: [String: Any]) {

        services = Self.strings(dictionary[Self.servicesKey])
        containers = Self.strings(dictionary[Self.containersKey]) + Self.strings(dictionary[Self.developmentContainersKey])
    }

    init(services: [String], containers: [String]) {

        self.services = services
        self.containers = containers
    }

    private static func strings(_ value: Any?) -> [String] {

        if let array = value as? [Any] { return array.compactMap { $0 as? String } }
        if let string = value as? String { return [string] }

        return []
    }

    /// Whether creating `CKContainer(identifier:)` would trap, as far as these entitlements tell.
    func problem(forContainer identifier: String) -> FeedbackUnavailableReason? {

        let hasCloudKit = services.contains { $0 == "CloudKit" || $0 == "CloudKit-Anonymous" || $0 == "*" }

        guard hasCloudKit else { return .missingCloudKitEntitlement }

        let listed = containers.contains { entry in

            if entry == identifier { return true }

            // Signed entitlements are concrete, but tolerate a trailing wildcard rather than block.
            if entry.hasSuffix("*") { return identifier.hasPrefix(String(entry.dropLast())) }

            return false
        }

        return listed ? nil : .containerNotInEntitlements(identifier)
    }

    /// A container identifier CloudKit can accept at all. Checked before the entitlements.
    static func identifierProblem(_ identifier: String) -> FeedbackUnavailableReason? {

        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed == identifier, identifier.hasPrefix("iCloud."), identifier.count > "iCloud.".count else {

            return .invalidContainerIdentifier(identifier)
        }

        return nil
    }

    /// The running executable's entitlements, or `nil` when they cannot be determined.
    ///
    /// A `static let`, so this runs at most once per process and only when first asked for - from
    /// `FeedbackContainer.prepare()`, i.e. when a feedback screen is first shown. Never at launch.
    static let current: CloudKitEntitlementFacts? = {

        guard let url = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }

        defer { try? handle.close() }

        let scan = MachOEntitlementScanner.scan(cpuType: MachOEntitlementScanner.currentCPUType) { offset, count in

            guard count >= 0, (try? handle.seek(toOffset: offset)) != nil else { return nil }

            return try? handle.read(upToCount: count)
        }

        #if targetEnvironment(simulator)
        return scan?.facts(preferSection: true, emptySignatureIsDefinite: false)
        #else
        return scan?.facts(preferSection: false, emptySignatureIsDefinite: true)
        #endif
    }()
}


/// Finds the entitlements in a Mach-O file: the code signature's XML entitlements slot (devices, the
/// Mac) and the `__TEXT,__entitlements` section (simulator builds). Pure, so it is unit tested on
/// synthetic binaries. Every read is bounds-checked and size-capped; malformed input gives `nil`.
enum MachOEntitlementScanner {

    struct Scan: Equatable {

        var hasSignature = false
        var signatureEntitlements: Data?
        var hasDEREntitlements = false
        var sectionEntitlements: Data?

        /// - Parameters:
        ///   - preferSection: The simulator keeps the real entitlements in the section.
        ///   - emptySignatureIsDefinite: A signature with no entitlements blob means "no entitlements"
        ///     on a device or the Mac, where the signature is what the system enforces.
        func facts(preferSection: Bool, emptySignatureIsDefinite: Bool) -> CloudKitEntitlementFacts? {

            let ordered = preferSection ? [sectionEntitlements, signatureEntitlements] : [signatureEntitlements, sectionEntitlements]

            for case let data? in ordered {

                // An unparseable blob is "unknown", never "missing".
                return CloudKitEntitlementFacts(plist: data)
            }

            if hasDEREntitlements { return nil }

            return hasSignature && emptySignatureIsDefinite ? CloudKitEntitlementFacts.empty : nil
        }
    }

    static let maximumBlobBytes = 4 * 1024 * 1024
    static let maximumLoadCommandBytes = 16 * 1024 * 1024

    static let cpuTypeARM64: UInt32 = 0x0100_000C
    static let cpuTypeX86_64: UInt32 = 0x0100_0007

    static var currentCPUType: UInt32 {

        #if arch(arm64)
        return cpuTypeARM64
        #else
        return cpuTypeX86_64
        #endif
    }

    private static let mhMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let lcSegment64: UInt32 = 0x19
    private static let lcCodeSignature: UInt32 = 0x1D
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsBlobMagic: UInt32 = 0xFADE_7171
    private static let slotEntitlements: UInt32 = 5
    private static let slotDEREntitlements: UInt32 = 7

    /// - Parameter read: Up to `count` bytes at `offset` from the start of the file; `nil` on failure.
    static func scan(cpuType: UInt32, read: (_ offset: UInt64, _ count: Int) -> Data?) -> Scan? {

        guard let magicBytes = read(0, 8), let magic = magicBytes.uint32BE(at: 0) else { return nil }

        var base: UInt64 = 0

        if magic == fatMagic || magic == fatMagic64 {

            guard let slice = fatSliceOffset(cpuType: cpuType, is64: magic == fatMagic64, read: read) else { return nil }

            base = slice
        }

        return scanThin(at: base, read: read)
    }

    private static func fatSliceOffset(cpuType: UInt32, is64: Bool, read: (UInt64, Int) -> Data?) -> UInt64? {

        guard let header = read(0, 8), let count = header.uint32BE(at: 4), count > 0, count <= 32 else { return nil }

        let entrySize = is64 ? 32 : 20

        guard let table = read(8, Int(count) * entrySize), table.count == Int(count) * entrySize else { return nil }

        for index in 0..<Int(count) {

            let entry = index * entrySize

            guard let type = table.uint32BE(at: entry), type == cpuType else { continue }

            let offset = is64 ? table.uint64BE(at: entry + 8) : table.uint32BE(at: entry + 8).map(UInt64.init)

            // Bounded so that later `base + offset` arithmetic can never overflow.
            guard let offset, offset < 1 << 40 else { return nil }

            return offset
        }

        return nil
    }

    private static func scanThin(at base: UInt64, read: (UInt64, Int) -> Data?) -> Scan? {

        guard let header = read(base, 32), header.count == 32, header.uint32LE(at: 0) == mhMagic64,
              let commandCount = header.uint32LE(at: 16), let commandBytes = header.uint32LE(at: 20),
              commandBytes <= UInt32(maximumLoadCommandBytes),
              let commands = read(base + 32, Int(commandBytes)), commands.count == Int(commandBytes) else { return nil }

        var result = Scan()
        var signature: (offset: UInt32, size: UInt32)?
        var offset = 0

        for _ in 0..<commandCount {

            guard let command = commands.uint32LE(at: offset), let size = commands.uint32LE(at: offset + 4),
                  size >= 8, offset + Int(size) <= commands.count else { return nil }

            if command == lcCodeSignature, let dataOffset = commands.uint32LE(at: offset + 8),
               let dataSize = commands.uint32LE(at: offset + 12) {

                signature = (dataOffset, dataSize)
            }
            else if command == lcSegment64, commands.fixedString(at: offset + 8, length: 16) == "__TEXT",
                    let sectionCount = commands.uint32LE(at: offset + 64) {

                for section in 0..<Int(min(sectionCount, 256)) {

                    let start = offset + 72 + section * 80

                    guard start + 80 <= offset + Int(size) else { break }

                    guard commands.fixedString(at: start, length: 16) == "__entitlements",
                          let length = commands.uint64LE(at: start + 40), length <= UInt64(maximumBlobBytes),
                          let fileOffset = commands.uint32LE(at: start + 48) else { continue }

                    if let data = read(base + UInt64(fileOffset), Int(length)), data.count == Int(length) {

                        result.sectionEntitlements = data
                    }
                }
            }

            offset += Int(size)
        }

        if let signature { scanSignature(at: base + UInt64(signature.offset), size: signature.size, into: &result, read: read) }

        return result
    }

    private static func scanSignature(at start: UInt64, size: UInt32, into result: inout Scan, read: (UInt64, Int) -> Data?) {

        guard size >= 12, let header = read(start, 12), header.uint32BE(at: 0) == superBlobMagic,
              let count = header.uint32BE(at: 8), count <= 64,
              let index = read(start + 12, Int(count) * 8), index.count == Int(count) * 8 else { return }

        result.hasSignature = true

        for slot in 0..<Int(count) {

            guard let type = index.uint32BE(at: slot * 8), let blobOffset = index.uint32BE(at: slot * 8 + 4),
                  blobOffset < size else { continue }

            if type == slotDEREntitlements { result.hasDEREntitlements = true }

            guard type == slotEntitlements,
                  let blobHeader = read(start + UInt64(blobOffset), 8),
                  blobHeader.uint32BE(at: 0) == entitlementsBlobMagic,
                  let length = blobHeader.uint32BE(at: 4), length >= 8, length - 8 <= UInt32(maximumBlobBytes),
                  let payload = read(start + UInt64(blobOffset) + 8, Int(length - 8)),
                  payload.count == Int(length - 8) else { continue }

            result.signatureEntitlements = payload
        }
    }
}


extension Data {

    fileprivate func byte(_ offset: Int) -> UInt8? {

        guard offset >= 0, offset < count else { return nil }

        return self[index(startIndex, offsetBy: offset)]
    }

    fileprivate func uint(at offset: Int, width: Int, bigEndian: Bool) -> UInt64? {

        guard offset >= 0, width > 0, offset <= count - width else { return nil }

        var value: UInt64 = 0

        for position in 0..<width {

            guard let byte = byte(offset + (bigEndian ? position : width - 1 - position)) else { return nil }

            value = value << 8 | UInt64(byte)
        }

        return value
    }

    func uint32LE(at offset: Int) -> UInt32? { uint(at: offset, width: 4, bigEndian: false).map { UInt32(truncatingIfNeeded: $0) } }
    func uint32BE(at offset: Int) -> UInt32? { uint(at: offset, width: 4, bigEndian: true).map { UInt32(truncatingIfNeeded: $0) } }
    func uint64LE(at offset: Int) -> UInt64? { uint(at: offset, width: 8, bigEndian: false) }
    func uint64BE(at offset: Int) -> UInt64? { uint(at: offset, width: 8, bigEndian: true) }

    /// A NUL-padded fixed-width C string, as in segment and section names.
    func fixedString(at offset: Int, length: Int) -> String? {

        guard offset >= 0, length > 0, offset <= count - length else { return nil }

        let bytes = (0..<length).compactMap { byte(offset + $0) }.prefix { $0 != 0 }

        return String(decoding: bytes, as: UTF8.self)
    }
}
