//
//  SchemaVariantTests.swift
//  SwiftUIFeatureBugReportTests
//

import Foundation
import Testing

@Suite("Checked-in CloudKit schemas")
struct SchemaVariantTests {

    private func schema(named name: String) throws -> String {

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return try String(contentsOf: repositoryRoot.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("Both variants define every required shared record type")
    func sharedTypes() throws {

        let schemas = try [schema(named: "Schema.ckdb"), schema(named: "Schema-NoComments.ckdb")]
        let required = ["Activity", "DevComment", "Follow", "PrivateReport", "PrivateReportDeletionRequest", "Report", "Request",
                        "RequestMetadata", "Users", "Vote"]

        for contents in schemas {

            for recordType in required {

                #expect(contents.contains("RECORD TYPE \(recordType) ("))
            }

            #expect(contents.contains("CREATE ROLE dev;"))
        }
    }

    @Test("Only the comments-enabled schema defines Comment")
    func commentVariant() throws {

        let comments = try schema(named: "Schema.ckdb")
        let noComments = try schema(named: "Schema-NoComments.ckdb")

        #expect(comments.contains("RECORD TYPE Comment ("))
        #expect(!noComments.contains("RECORD TYPE Comment ("))
    }

    /// The grant lines of one record type's block.
    private func grants(of recordType: String, in contents: String) throws -> Substring {

        let start = try #require(contents.range(of: "RECORD TYPE \(recordType) ("))
        let end = try #require(contents.range(of: ");", range: start.upperBound..<contents.endIndex))

        return contents[start.upperBound..<end.lowerBound]
    }

    /// The whole point of `PrivateReport`: CloudKit itself refuses other users, and the submitter can
    /// read but not write - otherwise they could forge developer replies or status. A `_world` grant or
    /// a creator WRITE slipping into either schema would break that.
    @Test("PrivateReport: creator READ only, dev READ/WRITE, no world, in both variants")
    func privateReportPermissions() throws {

        for name in ["Schema.ckdb", "Schema-NoComments.ckdb"] {

            let block = try grants(of: "PrivateReport", in: try schema(named: name))

            #expect(!block.contains("_world"))
            #expect(block.contains("GRANT READ TO \"_creator\""))
            #expect(!block.contains("WRITE TO \"_creator\""))
            #expect(block.contains("GRANT CREATE TO \"_icloud\""))
            #expect(block.contains("GRANT READ, WRITE TO dev"))
        }
    }

    @Test("PrivateReportDeletionRequest has the same grants as PrivateReport, in both variants")
    func deletionRequestPermissions() throws {

        for name in ["Schema.ckdb", "Schema-NoComments.ckdb"] {

            let block = try grants(of: "PrivateReportDeletionRequest", in: try schema(named: name))

            #expect(!block.contains("_world"))
            #expect(block.contains("GRANT READ TO \"_creator\""))
            #expect(!block.contains("WRITE TO \"_creator\""))
            #expect(block.contains("GRANT CREATE TO \"_icloud\""))
            #expect(block.contains("GRANT READ, WRITE TO dev"))
        }
    }
}
