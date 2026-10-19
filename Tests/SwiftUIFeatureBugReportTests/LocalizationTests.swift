//
//  LocalizationTests.swift
//  SwiftUIFeatureBugReportTests
//
//  The package ships its own Simplified Chinese. These check the built bundle really carries it, and -
//  by reading the sources next to this file - that every string the package looks up is in the
//  catalogue with a translation, and that no SwiftUI call still looks a literal up in `Bundle.main`.
//

import Foundation
import Testing

@testable import SwiftUIFeatureBugReport

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let sourcesRoot = packageRoot.appendingPathComponent("Sources/SwiftUIFeatureBugReport")

private let catalogURL = sourcesRoot.appendingPathComponent("Resources/Localizable.xcstrings")

private func localization(_ language: String) throws -> Bundle {

    let path = try #require(Bundle.feedbackResources.path(forResource: language, ofType: "lproj"),
                            "\(language).lproj missing from \(Bundle.feedbackResources.bundlePath)")

    return try #require(Bundle(path: path))
}

@Suite("Built-in localisation")
struct LocalizationTests {

    @Test("The package's own resource bundle is found, without trapping, and carries zh-Hans")
    func bundle() {

        #expect(Bundle.feedbackResources != Bundle.main)
        #expect(Bundle.feedbackResources.bundleURL.lastPathComponent.hasSuffix("_SwiftUIFeatureBugReport.bundle"))
        #expect(Bundle.feedbackResources.localizations.contains("zh-Hans"))
    }

    @Test("Known strings translate to Simplified Chinese")
    func knownTranslations() throws {

        let zh = try localization("zh-Hans")

        let expected = [
            "Feedback": "反馈",
            "Submit": "提交",
            "Developer portal": "开发者后台",
            "Private": "私密",
            "Bug": "问题",
            "Feature": "功能建议",
            "Cancel": "取消",
            "My private reports": "我的私密反馈",
            "New request": "新反馈",
        ]

        for (key, value) in expected {

            #expect(zh.localizedString(forKey: key, value: "MISSING", table: nil) == value, "\(key)")
        }
    }

    @Test("Plural strings: English one/other, Chinese without plural forms")
    func plurals() throws {

        let en = try localization("en-GB")
        let zh = try localization("zh-Hans")
        let gb = Locale(identifier: "en_GB")

        func english(_ key: String, _ arguments: any CVarArg...) -> String {

            String(format: en.localizedString(forKey: key, value: nil, table: nil), locale: gb, arguments: arguments)
        }

        #expect(english("%lld votes", 1) == "1 vote")
        #expect(english("%lld votes", 3) == "3 votes")
        #expect(english("%lld files", 1) == "1 file")
        #expect(english("%lld replies", 2) == "2 replies")
        #expect(english("Voted. %lld votes", 1) == "Voted. 1 vote")
        #expect(english("%lld votes · %@", 1, "2.0 (5)") == "1 vote · 2.0 (5)")
        #expect(english("%lld reports reached the threshold of %lld, so users can no longer see this. Clear reports to restore it.", 1, 3)
                == "1 report reached the threshold of 3, so users can no longer see this. Clear reports to restore it.")

        let chinese = String(format: zh.localizedString(forKey: "%lld files", value: nil, table: nil),
                             locale: Locale(identifier: "zh_Hans"), 1)

        #expect(chinese == "1 个文件")
    }

    @Test("Every catalogue entry has a Chinese translation with the same format arguments")
    func catalogueIsComplete() throws {

        let catalog = try Catalog.load()

        #expect(catalog.sourceLanguage == "en-GB")
        #expect(catalog.entries.count > 300)

        for (key, entry) in catalog.entries {

            let value = try #require(entry.chinese, "no zh-Hans for \(key)")

            #expect(!value.isEmpty, "empty zh-Hans for \(key)")
            #expect(Catalog.specifiers(value) == Catalog.specifiers(key), "format arguments differ: \(key) -> \(value)")
        }
    }

    @Test("Every string the sources look up is in the catalogue, and nothing in the catalogue is stale")
    func sourcesMatchCatalogue() throws {

        let catalog = try Catalog.load()
        let sources = try SourceStrings.load()

        #expect(sources.lookedUp.count > 300)

        for literal in sources.lookedUp {

            #expect(catalog.entries.keys.contains { literal.matches($0) }, "not in the catalogue: \(literal.text) (\(literal.location))")
        }

        for key in catalog.entries.keys {

            #expect(sources.all.contains { $0.matches(key) }, "catalogue key no longer used: \(key)")
        }
    }

    /// A literal handed straight to one of these resolves in the host app's bundle and stays English.
    @Test("No SwiftUI call takes a bare string literal")
    func noBareLiterals() throws {

        let patterns = [
            #"\bText\("(?:[^"\\]|\\.)*"\)"#,
            #"\b(?:Button|Label|Toggle|Section|TextField|SecureField|LabeledContent|ProgressView|Link|Menu|ContentUnavailableView)\("(?:[^"\\]|\\.)+""#,
            #"\bPicker\("(?:[^"\\]|\\.)+""#,
            #"\.(?:navigationTitle|help|alert|confirmationDialog|accessibilityLabel|accessibilityHint|badge)\("(?:[^"\\]|\\.)+""#,
            #"String\(localized: "(?:[^"\\]|\\.)*"\)"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        for file in try SourceStrings.swiftFiles() {

            let text = try String(contentsOf: file, encoding: .utf8)

            for (number, line) in text.components(separatedBy: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {

                let range = NSRange(line.startIndex..., in: line)

                for pattern in patterns where pattern.firstMatch(in: line, range: range) != nil {

                    Issue.record("\(file.lastPathComponent):\(number + 1) looks a literal up in Bundle.main: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}


// MARK: - Helpers

private struct Catalog {

    struct Entry { let chinese: String? }

    let sourceLanguage: String
    let entries: [String: Entry]

    static func load() throws -> Catalog {

        let data = try Data(contentsOf: catalogURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])

        var entries: [String: Entry] = [:]

        for (key, value) in strings {

            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            let zh = localizations?["zh-Hans"] as? [String: Any]
            let unit = zh?["stringUnit"] as? [String: Any]

            entries[key] = Entry(chinese: unit?["value"] as? String)
        }

        return Catalog(sourceLanguage: json["sourceLanguage"] as? String ?? "", entries: entries)
    }

    /// The kinds of format arguments, in order of position, ignoring explicit `%1$` numbering.
    static func specifiers(_ string: String) -> [String] {

        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?(lld|ld|d|@|lf|f)"#)
        let matches = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))

        let numbered = matches.enumerated().map { index, match -> (Int, String) in

            let position = Range(match.range(at: 1), in: string).flatMap { Int(string[$0].dropLast()) } ?? index + 1

            return (position, String(string[Range(match.range(at: 2), in: string)!]))
        }

        return numbered.sorted { $0.0 < $1.0 }.map(\.1)
    }
}


/// The string literals in the package's sources, with interpolations turned into "any format argument".
private struct SourceStrings {

    struct Literal {

        let text: String
        let location: String
        let pattern: NSRegularExpression

        func matches(_ key: String) -> Bool {

            pattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
        }
    }

    /// Literals passed to the package's own lookups: `loc`, `locResource`, `Text(_, bundle:)`,
    /// `String(localized:bundle:)`, and the internal views whose parameters are `LocalizedStringKey`.
    let lookedUp: [Literal]

    /// Every literal, to tell a stale catalogue key from one used through a variable.
    let all: [Literal]

    static func swiftFiles() throws -> [URL] {

        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)

        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    static func load() throws -> SourceStrings {

        var lookedUp: [Literal] = []
        var all: [Literal] = []

        for file in try swiftFiles() {

            let text = try String(contentsOf: file, encoding: .utf8)
            let scalars = Array(text)

            var index = 0
            var line = 1

            while index < scalars.count {

                let character = scalars[index]

                if character == "\n" { line += 1 }

                if character == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {

                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }

                guard character == "\"" else { index += 1; continue }

                let (end, body) = scanLiteral(scalars, from: index)
                let lineStart = scalars[..<index].lastIndex(of: "\n").map { $0 + 1 } ?? 0
                let before = String(scalars[lineStart..<index])
                let lineEnd = scalars[end...].firstIndex(of: "\n") ?? scalars.count
                let after = String(scalars[end..<lineEnd])

                let literal = Literal(text: body, location: "\(file.lastPathComponent):\(line)", pattern: pattern(for: body))

                all.append(literal)

                if Self.isLookup(before: before, after: after, inViews: file.path.contains("/Views/")) {

                    lookedUp.append(literal)
                }

                index = end
            }
        }

        return SourceStrings(lookedUp: lookedUp, all: all)
    }

    /// Whether a literal sits in a position the package looks up: the argument of `loc` or
    /// `locResource`, the key of `Text(_:bundle:)` / `String(localized:bundle:)` (or a ternary branch of
    /// one), or a `LocalizedStringKey` parameter of the package's own views.
    private static func isLookup(before: String, after: String, inViews: Bool) -> Bool {

        let bundled = (before + after).contains("bundle: .feedbackResources")

        if before.hasSuffix("loc(") || before.hasSuffix("locResource(") { return true }
        if before.range(of: #"\bText\($"#, options: .regularExpression) != nil { return bundled }
        if before.range(of: #"localized:\s*$"#, options: .regularExpression) != nil { return bundled }
        if before.range(of: #"\bText\([^"]*\?\s*$|\bText\([^"]*"[^"]*"\s*:\s*$"#, options: .regularExpression) != nil { return bundled }

        guard inViews else { return false }

        // `FeedbackEmptyState(title:message:)`, `FeedbackTextEditor(placeholder:)`, `listTitle:`,
        // `sendButton(title:)`, including a ternary between two literals.
        return before.range(of: #"\b(?:title|message|placeholder|listTitle):\s*(?:[^"]*\?\s*)?$"#, options: .regularExpression) != nil
            || before.range(of: #"^\s*:\s*$"#, options: .regularExpression) != nil
    }

    /// Returns the index after the closing quote and the literal's contents with each interpolation
    /// replaced by a marker.
    private static func scanLiteral(_ s: [Character], from start: Int) -> (Int, String) {

        var index = start + 1
        var body = ""

        while index < s.count {

            let character = s[index]

            if character == "\\", index + 1 < s.count {

                if s[index + 1] == "(" {

                    var depth = 0
                    index += 1

                    repeat {

                        if s[index] == "\"" { index = scanLiteral(s, from: index).0; continue }
                        if s[index] == "(" { depth += 1 }
                        if s[index] == ")" { depth -= 1 }

                        index += 1
                    } while depth > 0 && index < s.count

                    body.append("\u{1}")
                    continue
                }

                let escaped = s[index + 1]

                body.append(escaped == "n" ? "\n" : escaped)
                index += 2
                continue
            }

            if character == "\"" { return (index + 1, body) }

            body.append(character)
            index += 1
        }

        return (index, body)
    }

    private static func pattern(for body: String) -> NSRegularExpression {

        let escaped = NSRegularExpression.escapedPattern(for: body)
            .replacingOccurrences(of: "\u{1}", with: #"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)"#)
            // A literal `%` in source text is not a format argument; keep it literal.

        return try! NSRegularExpression(pattern: "^" + escaped + "$")
    }
}
