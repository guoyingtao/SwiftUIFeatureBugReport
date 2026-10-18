//
//  CrashSafetyTests.swift
//  SwiftUIFeatureBugReportTests
//
//  The test runner is not signed with any iCloud entitlement, so `CKContainer(identifier:)` traps
//  here - the same uncatchable crash a host app without the capability gets. Every test below that
//  constructs a store or a view would have killed the whole test process before these fixes.
//

import CloudKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import SwiftUIFeatureBugReport

private let configuration = FeedbackConfiguration(containerIdentifier: "iCloud.com.example.feedback")

/// Whether this process's entitlements were read and rule CloudKit out - the only case in which it is
/// safe to call `prepare()` here, since anything else would create a container and trap.
private let entitlementsRuleOutCloudKit: Bool = {

    CloudKitEntitlementFacts.current?.problem(forContainer: configuration.containerIdentifier) != nil
}()

@Suite("Nothing happens before a feedback screen is shown")
@MainActor struct LazyConstructionTests {

    @Test("Constructing a store creates no container")
    func storeConstructionIsInert() {

        let store = FeedbackStore(configuration: configuration)

        #expect(store.configuration.containerIdentifier == configuration.containerIdentifier)
        #expect(store.container.identityState == .resolving)
    }

    @Test("Constructing every public view is inert, as NavigationLink(destination:) does")
    func viewConstructionIsInert() {

        _ = FeedbackBoardView(configuration: configuration)
        _ = FeedbackFormView(configuration: configuration)
        _ = RoadmapView(configuration: configuration)
        _ = UpdatesView(configuration: configuration)
        _ = MyDataView(configuration: configuration)
        _ = DeveloperPortalView(configuration: configuration)
        _ = PrivateReportsView(configuration: configuration)

        let store = FeedbackStore(configuration: configuration)

        _ = FeedbackBoardView(store: store)
        _ = FeedbackFormView(store: store)
    }

    @Test("A gate with a configuration builds its store once, on first resolve")
    func lazyStoreIsBuiltOnce() {

        let box = LazyFeedbackStore()
        let first = box.resolve(.configuration(configuration))
        let second = box.resolve(.configuration(configuration))

        #expect(first === second)

        let shared = FeedbackStore(configuration: configuration)

        #expect(box.resolve(.store(shared)) === shared)
    }

    @Test("Without the entitlement, prepare() reports unavailable instead of trapping",
          .enabled(if: entitlementsRuleOutCloudKit))
    func prepareDegrades() async {

        let store = FeedbackStore(configuration: configuration)

        guard case .unavailable = store.prepare() else {

            Issue.record("Expected .unavailable")
            return
        }

        #expect(store.container.unavailableReason != nil)

        // `start()` and `load()` must stop before CloudKit and surface a failed identity.
        await store.start()
        await store.load()

        guard case .failed = store.container.identityState else {

            Issue.record("Expected a failed identity, got \(store.container.identityState)")
            return
        }

        #expect(store.canWrite == false)
    }

    @Test("An invalid container identifier is unavailable whatever the entitlements")
    func invalidIdentifierDegrades() {

        for identifier in ["", "com.example.feedback", "iCloud.", " iCloud.com.example"] {

            let store = FeedbackStore(configuration: FeedbackConfiguration(containerIdentifier: identifier))

            #expect(store.prepare() == .unavailable(.invalidContainerIdentifier(identifier)))
        }
    }
}


@Suite("Entitlement checks")
struct EntitlementFactsTests {

    private let identifier = "iCloud.com.echo.feedback"

    @Test("CloudKit plus the container is fine")
    func configured() {

        let facts = CloudKitEntitlementFacts(services: ["CloudKit"], containers: ["iCloud.com.other", identifier])

        #expect(facts.problem(forContainer: identifier) == nil)
    }

    @Test("CloudKit-Anonymous counts as CloudKit")
    func anonymous() {

        let facts = CloudKitEntitlementFacts(services: ["CloudKit-Anonymous"], containers: [identifier])

        #expect(facts.problem(forContainer: identifier) == nil)
    }

    @Test("Missing services, or iCloud Documents only, is missing CloudKit")
    func missingServices() {

        #expect(CloudKitEntitlementFacts.empty.problem(forContainer: identifier) == .missingCloudKitEntitlement)
        #expect(CloudKitEntitlementFacts(services: ["CloudDocuments"], containers: [identifier])
            .problem(forContainer: identifier) == .missingCloudKitEntitlement)
    }

    @Test("Another app's container only is reported by name")
    func missingContainer() {

        let facts = CloudKitEntitlementFacts(services: ["CloudKit"], containers: ["iCloud.com.echo.beeday"])

        #expect(facts.problem(forContainer: identifier) == .containerNotInEntitlements(identifier))
    }

    @Test("A wildcard entry is tolerated rather than blocking")
    func wildcard() {

        let facts = CloudKitEntitlementFacts(services: ["*"], containers: ["iCloud.com.echo.*"])

        #expect(facts.problem(forContainer: identifier) == nil)
    }

    @Test("Parses an entitlements plist, including the development container list")
    func parsesPlist() throws {

        let plist: [String: Any] = [
            CloudKitEntitlementFacts.servicesKey: ["CloudKit"],
            CloudKitEntitlementFacts.developmentContainersKey: [identifier],
            "aps-environment": "development"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let facts = try #require(CloudKitEntitlementFacts(plist: data))

        #expect(facts.services == ["CloudKit"])
        #expect(facts.problem(forContainer: identifier) == nil)
        #expect(CloudKitEntitlementFacts(plist: Data("not a plist".utf8)) == nil)
    }

    @Test("Reading this process's own entitlements does not crash")
    func readsCurrentProcess() {

        // Unsigned or linker-signed test runners have none; whatever the answer, it must not trap.
        _ = CloudKitEntitlementFacts.current
    }
}


@Suite("Mach-O entitlement scanning")
struct MachOEntitlementScannerTests {

    private static let entitlementsPlist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
        <key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.echo.feedback</string></array>
        </dict></plist>
        """.utf8)

    private static func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private static func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private static func le64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

    private static func name16(_ text: String) -> [UInt8] {

        Array(text.utf8) + Array(repeating: 0, count: 16 - text.utf8.count)
    }

    /// A minimal 64-bit Mach-O: header, optional `__TEXT` segment with an `__entitlements` section,
    /// and an `LC_CODE_SIGNATURE` pointing at a super blob with the given slots.
    private static func machO(signatureSlots: [(type: UInt32, blob: [UInt8])]?, section: Data? = nil) -> [UInt8] {

        var commands: [UInt8] = []
        var commandCount: UInt32 = 0
        let headerSize = 32
        let segmentSize = 72 + 80
        let signatureCommandSize = 16
        let commandsSize = (section == nil ? 0 : segmentSize) + (signatureSlots == nil ? 0 : signatureCommandSize)
        var payload: [UInt8] = []
        let payloadStart = headerSize + commandsSize

        if let section {

            let sectionOffset = UInt32(payloadStart + payload.count)

            payload += Array(section)

            commands += le32(0x19) + le32(UInt32(segmentSize)) + name16("__TEXT")
            commands += le64(0) + le64(0) + le64(0) + le64(0)              // vmaddr, vmsize, fileoff, filesize
            commands += le32(5) + le32(5) + le32(1) + le32(0)              // maxprot, initprot, nsects, flags
            commands += name16("__entitlements") + name16("__TEXT")
            commands += le64(0) + le64(UInt64(section.count))              // addr, size
            commands += le32(sectionOffset) + le32(0) + le32(0) + le32(0)  // offset, align, reloff, nreloc
            commands += le32(0) + le32(0) + le32(0) + le32(0)              // flags, reserved1-3
            commandCount += 1
        }

        if let signatureSlots {

            let signatureOffset = UInt32(payloadStart + payload.count)
            var blobs: [UInt8] = []
            var index: [UInt8] = []
            let headerAndIndex = 12 + signatureSlots.count * 8

            for slot in signatureSlots {

                index += be32(slot.type) + be32(UInt32(headerAndIndex + blobs.count))
                blobs += slot.blob
            }

            let superBlob = be32(0xFADE_0CC0) + be32(UInt32(headerAndIndex + blobs.count)) + be32(UInt32(signatureSlots.count)) + index + blobs

            payload += superBlob

            commands += le32(0x1D) + le32(16) + le32(signatureOffset) + le32(UInt32(superBlob.count))
            commandCount += 1
        }

        let header = le32(0xFEED_FACF) + le32(MachOEntitlementScanner.cpuTypeARM64) + le32(0) + le32(2)
            + le32(commandCount) + le32(UInt32(commands.count)) + le32(0) + le32(0)

        return header + commands + payload
    }

    private static func entitlementsBlob(_ plist: Data) -> [UInt8] {

        be32(0xFADE_7171) + be32(UInt32(plist.count + 8)) + Array(plist)
    }

    private static func scan(_ bytes: [UInt8], cpuType: UInt32 = MachOEntitlementScanner.cpuTypeARM64) -> MachOEntitlementScanner.Scan? {

        let data = Data(bytes)

        return MachOEntitlementScanner.scan(cpuType: cpuType) { offset, count in

            guard offset <= UInt64(data.count) else { return nil }

            let start = Int(offset)

            return data.subdata(in: start..<min(data.count, start + count))
        }
    }

    @Test("Reads the entitlements slot of a code signature")
    func signatureSlot() throws {

        let bytes = Self.machO(signatureSlots: [(0, Self.be32(0xFADE_0C02) + Self.be32(8)),
                                                (5, Self.entitlementsBlob(Self.entitlementsPlist))])
        let scan = try #require(Self.scan(bytes))
        let facts = try #require(scan.facts(preferSection: false, emptySignatureIsDefinite: true))

        #expect(scan.hasSignature)
        #expect(facts.problem(forContainer: "iCloud.com.echo.feedback") == nil)
        #expect(facts.problem(forContainer: "iCloud.com.echo.other") == .containerNotInEntitlements("iCloud.com.echo.other"))
    }

    @Test("Reads the simulator's __entitlements section, preferred when asked")
    func section() throws {

        let partial = try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": true], format: .xml, options: 0)
        let bytes = Self.machO(signatureSlots: [(5, Self.entitlementsBlob(partial))], section: Self.entitlementsPlist)
        let scan = try #require(Self.scan(bytes))

        #expect(scan.facts(preferSection: true, emptySignatureIsDefinite: false)?.problem(forContainer: "iCloud.com.echo.feedback") == nil)
        #expect(scan.facts(preferSection: false, emptySignatureIsDefinite: true)?.problem(forContainer: "iCloud.com.echo.feedback")
            == .missingCloudKitEntitlement)
    }

    @Test("A signature with no entitlements is definite only where the signature is enforced")
    func emptySignature() throws {

        let scan = try #require(Self.scan(Self.machO(signatureSlots: [(0, Self.be32(0xFADE_0C02) + Self.be32(8))])))

        #expect(scan.facts(preferSection: false, emptySignatureIsDefinite: true) == CloudKitEntitlementFacts.empty)
        #expect(scan.facts(preferSection: true, emptySignatureIsDefinite: false) == nil)
    }

    @Test("DER-only entitlements, or no signature at all, are unknown")
    func unknown() throws {

        let der = try #require(Self.scan(Self.machO(signatureSlots: [(7, Self.be32(0xFADE_7172) + Self.be32(8))])))

        #expect(der.facts(preferSection: false, emptySignatureIsDefinite: true) == nil)

        let unsigned = try #require(Self.scan(Self.machO(signatureSlots: nil)))

        #expect(unsigned.facts(preferSection: false, emptySignatureIsDefinite: true) == nil)
    }

    @Test("Finds the matching slice of a fat binary")
    func fat() throws {

        let thin = Self.machO(signatureSlots: [(5, Self.entitlementsBlob(Self.entitlementsPlist))])
        let sliceOffset: UInt32 = 4096
        var fat = Self.be32(0xCAFE_BABE) + Self.be32(2)

        fat += Self.be32(MachOEntitlementScanner.cpuTypeX86_64) + Self.be32(3) + Self.be32(0) + Self.be32(0) + Self.be32(12)
        fat += Self.be32(MachOEntitlementScanner.cpuTypeARM64) + Self.be32(0) + Self.be32(sliceOffset) + Self.be32(UInt32(thin.count)) + Self.be32(14)
        fat += Array(repeating: 0, count: Int(sliceOffset) - fat.count) + thin

        let scan = try #require(Self.scan(fat))

        #expect(scan.facts(preferSection: false, emptySignatureIsDefinite: true)?.problem(forContainer: "iCloud.com.echo.feedback") == nil)
        #expect(Self.scan(fat, cpuType: 0x0000_0007) == nil)
    }

    @Test("Garbage and truncated input give nil, never a crash")
    func malformed() {

        #expect(Self.scan([]) == nil)
        #expect(Self.scan([0xCF, 0xFA]) == nil)
        #expect(Self.scan(Array(repeating: 0xFF, count: 64)) == nil)

        let good = Self.machO(signatureSlots: [(5, Self.entitlementsBlob(Self.entitlementsPlist))])

        // Every truncation either parses (when only the tail was lost) or fails cleanly.
        for length in stride(from: 0, to: good.count, by: 7) { _ = Self.scan(Array(good.prefix(length))) }

        // Absurd counts and sizes in the header.
        var hostile = good
        hostile.replaceSubrange(16..<24, with: Self.le32(.max) + Self.le32(.max))

        #expect(Self.scan(hostile) == nil)
    }
}


@Suite("Runtime trap guards")
struct RuntimeGuardTests {

    @Test("Server retry hints that would trap Duration or Int are sanitised")
    func retryDelay() {

        #expect(CloudKitErrorHandler.sanitizedDelay(.infinity) == nil)
        #expect(CloudKitErrorHandler.sanitizedDelay(.nan) == nil)
        #expect(CloudKitErrorHandler.sanitizedDelay(-1) == nil)
        #expect(CloudKitErrorHandler.sanitizedDelay(1e300) == CloudKitErrorHandler.maximumRetryDelay)
        #expect(CloudKitErrorHandler.sanitizedDelay(2.5) == 2.5)

        let error = CKError(_nsError: NSError(domain: CKError.errorDomain,
                                              code: CKError.Code.requestRateLimited.rawValue,
                                              userInfo: [CKErrorRetryAfterKey: Double.infinity]))

        #expect(CloudKitErrorHandler.retryDelay(for: error) == nil)

        // Formatting an already-built error with a hostile value must not trap either.
        #expect(FeedbackError.rateLimited(retryAfter: .infinity).errorDescription?.isEmpty == false)
        #expect(FeedbackError.rateLimited(retryAfter: .nan).errorDescription?.isEmpty == false)
    }

    @Test("Previews are decoded downsampled, never at full size")
    func downsampledPreview() throws {

        let data = NSMutableData()
        let context = try #require(CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))

        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let preview = try #require(FeedbackImage.downsampled(source, maxPixelSize: 300))

        #expect(max(preview.width, preview.height) == 300)

        let empty = try #require(CGImageSourceCreateWithData(Data() as CFData, nil))

        #expect(FeedbackImage.downsampled(empty, maxPixelSize: 300) == nil)
    }
}
