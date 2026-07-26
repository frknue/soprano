import AppKit
import Testing
@testable import Soprano

struct JSONCTextTests {

    // MARK: - Reading

    @Test func stripsLineAndBlockCommentsBeforeHandingTheDocumentToTheDecoder() throws {
        let text = """
        // a leading note
        {
          // about a
          "a": 1, /* inline */ "b": 2,
          /* a block
             spanning lines */
          "c": 3
        }
        """

        let values = try topLevelObject(of: text)
        #expect(values["a"] as? Int == 1)
        #expect(values["b"] as? Int == 2)
        #expect(values["c"] as? Int == 3)
    }

    @Test func leavesCommentLikeTextInsideStringValuesAlone() throws {
        let text = #"{"url": "https://example.com//path", "note": "a /* not a comment */ b"}"#

        let values = try topLevelObject(of: text)
        #expect(values["url"] as? String == "https://example.com//path")
        #expect(values["note"] as? String == "a /* not a comment */ b")
    }

    @Test func handlesEscapedQuotesEscapedBackslashesAndCommentsContainingQuotes() throws {
        let text = #"""
        {
          "quote": "she said \"hi\" // not a comment",
          "path": "C:\\temp\\",
          /* the comment says "hi" and /* looks nested */
          "kept": true
        }
        """#

        let values = try topLevelObject(of: text)
        #expect(values["quote"] as? String == #"she said "hi" // not a comment"#)
        #expect(values["path"] as? String == #"C:\temp\"#)
        #expect(values["kept"] as? Bool == true)
    }

    @Test func acceptsTrailingCommasInObjectsAndArrays() throws {
        let text = """
        {
          "list": [1, 2, 3,],
          "nested": { "x": 1, },
        }
        """

        let values = try topLevelObject(of: text)
        #expect(values["list"] as? [Int] == [1, 2, 3])
        #expect((values["nested"] as? [String: Any])?["x"] as? Int == 1)
    }

    @Test func decodesJSONCTextIntoACodableValue() throws {
        let text = """
        // sample settings
        {
          "name": "soprano", // the app
          "count": 3,
          /* trailing comma below is fine */
          "flags": ["a", "b",],
        }
        """

        let sample = try JSONCText.decode(Sample.self, from: text)
        #expect(sample == Sample(name: "soprano", count: 3, flags: ["a", "b"]))
    }

    @Test func reportsErrorPositionsFromTheOriginalDocumentEvenAfterStrippingComments() throws {
        let lineCommented = """
        {
          // the entry below is missing its comma
          "a": 1
          "b": 2
        }
        """
        let lineError = parseError(from: lineCommented)
        #expect(lineError?.message == "Expected ','")
        #expect(lineError?.line == 4)
        #expect(lineError?.column == 3)
        #expect(lineError?.description == "Expected ',' (line 4, column 3)")

        // The same document, but with a multi-line block comment above the
        // error: stripping must not shift a single character.
        let blockCommented = """
        {
          /* a block comment
             spanning two lines */
          "a": 1
          "b": 2
        }
        """
        let blockError = parseError(from: blockCommented)
        #expect(blockError?.line == 5)
        #expect(blockError?.column == 3)

        #expect(parseError(from: "{\n  \"a\": /* nope */ }")?.line == 2)
        #expect(parseError(from: "{ /* never closed")?.message == "Unterminated block comment")
    }

    // MARK: - Setting

    @Test func settingAnExistingKeyKeepsTheCommentAboveItAndTheCommentOnItsLine() throws {
        let text = """
        {
          // font size in points
          "fontSize": 13, // tweak me
          "theme": "gruvbox-dark"
        }
        """

        let updated = try JSONCText.setting(16, at: ["fontSize"], in: text)
        #expect(updated == """
        {
          // font size in points
          "fontSize": 16, // tweak me
          "theme": "gruvbox-dark"
        }
        """)
        let values = try topLevelObject(of: updated)
        #expect(values["fontSize"] as? Int == 16)
    }

    @Test func settingAMissingTopLevelKeyAppendsItWithTheSiblingIndentation() throws {
        let updated = try JSONCText.setting("dark", at: ["theme"], in: "{\n  \"a\": 1\n}")
        #expect(updated == "{\n  \"a\": 1,\n  \"theme\": \"dark\"\n}")

        // An existing trailing comma is reused rather than doubled.
        let afterTrailingComma = try JSONCText.setting("dark", at: ["theme"], in: "{\n  \"a\": 1,\n}")
        #expect(afterTrailingComma == "{\n  \"a\": 1,\n  \"theme\": \"dark\"\n}")

        // The separating comma belongs before a trailing comment, not inside it.
        let withComment = try JSONCText.setting(2, at: ["b"], in: "{\n  \"a\": 1 // hi\n}")
        #expect(withComment == "{\n  \"a\": 1, // hi\n  \"b\": 2\n}")
        let values = try topLevelObject(of: withComment)
        #expect(values["b"] as? Int == 2)

        // A one-line object stays a one-line object.
        #expect(try JSONCText.setting(2, at: ["b"], in: "{ \"a\": 1 }") == "{ \"a\": 1, \"b\": 2 }")
    }

    @Test func settingRespectsTheIndentUnitTheDocumentAlreadyUses() throws {
        #expect(try JSONCText.setting(2, at: ["b"], in: "{\n    \"a\": 1\n}")
            == "{\n    \"a\": 1,\n    \"b\": 2\n}")
        #expect(try JSONCText.setting(2, at: ["b"], in: "{\n\t\"a\": 1\n}")
            == "{\n\t\"a\": 1,\n\t\"b\": 2\n}")
    }

    @Test func settingThroughAMissingIntermediateObjectCreatesTheWholeChain() throws {
        let created = try JSONCText.setting("a", at: ["keybindings", "prefixKey"], in: "{}")
        #expect(created == """
        {
          "keybindings": {
            "prefixKey": "a"
          }
        }
        """)
        let createdValues = try topLevelObject(of: created)
        let keybindings = createdValues["keybindings"] as? [String: Any]
        #expect(keybindings?["prefixKey"] as? String == "a")

        let deep = try JSONCText.setting(1, at: ["a", "b", "c"], in: "{\n  \"z\": 0\n}")
        #expect(deep == """
        {
          "z": 0,
          "a": {
            "b": {
              "c": 1
            }
          }
        }
        """)

        // A scalar standing where an object is needed is replaced outright.
        let replaced = try JSONCText.setting(1, at: ["a", "b"], in: "{\n  \"a\": \"scalar\"\n}")
        #expect(replaced == "{\n  \"a\": {\n    \"b\": 1\n  }\n}")
    }

    @Test func settingIntoAnEmptyOrCommentOnlyDocumentProducesAValidFile() throws {
        #expect(try JSONCText.setting("dark", at: ["theme"], in: "")
            == "{\n  \"theme\": \"dark\"\n}\n")
        #expect(try JSONCText.setting("dark", at: ["theme"], in: "   \n\n")
            == "{\n  \"theme\": \"dark\"\n}\n")

        let fromComment = try JSONCText.setting("dark", at: ["theme"], in: "// hello\n")
        #expect(fromComment == "// hello\n{\n  \"theme\": \"dark\"\n}\n")
        let values = try topLevelObject(of: fromComment)
        #expect(values["theme"] as? String == "dark")
    }

    @Test func writesArrayAndDictionaryValuesPrettyPrintedAtTheirOwnDepth() throws {
        let base = "{\n  \"theme\": \"x\"\n}"

        let withArray = try JSONCText.setting(["~/a", "~/b"], at: ["projects"], in: base)
        #expect(withArray == """
        {
          "theme": "x",
          "projects": [
            "~/a",
            "~/b"
          ]
        }
        """)
        let arrayValues = try topLevelObject(of: withArray)
        #expect(arrayValues["projects"] as? [String] == ["~/a", "~/b"])

        // Dictionary keys are sorted so writes stay deterministic.
        let withDictionary = try JSONCText.setting(
            ["prefixTimeoutMs": 900, "prefixKey": "b"] as [String: Any],
            at: ["keybindings"],
            in: base
        )
        #expect(withDictionary == """
        {
          "theme": "x",
          "keybindings": {
            "prefixKey": "b",
            "prefixTimeoutMs": 900
          }
        }
        """)

        let nested = try JSONCText.setting(
            ["x": ["y": [1, 2]]] as [String: Any],
            at: ["a", "b"],
            in: "{\n  \"a\": {\n    \"keep\": true\n  }\n}"
        )
        #expect(nested == """
        {
          "a": {
            "keep": true,
            "b": {
              "x": {
                "y": [
                  1,
                  2
                ]
              }
            }
          }
        }
        """)
        let nestedValues = try topLevelObject(of: nested)
        #expect(nestedValues.isEmpty == false)

        let scalars = try JSONCText.setting(
            ["flag": true, "nothing": NSNull(), "ratio": 1.5, "empty": [String: Any]()] as [String: Any],
            at: ["misc"],
            in: base
        )
        let scalarValues = try topLevelObject(of: scalars)
        let misc = scalarValues["misc"] as? [String: Any]
        #expect(misc?["flag"] as? Bool == true)
        #expect(misc?["nothing"] is NSNull)
        #expect(misc?["ratio"] as? Double == 1.5)
        #expect((misc?["empty"] as? [String: Any])?.isEmpty == true)
    }

    // MARK: - Removing

    @Test func removingDropsTheKeyItsValueAndExactlyOneAdjacentComma() throws {
        let text = """
        {
          "a": 1,
          "b": 2,
          "c": 3
        }
        """

        #expect(try JSONCText.removing(at: ["a"], in: text) == "{\n  \"b\": 2,\n  \"c\": 3\n}")
        #expect(try JSONCText.removing(at: ["b"], in: text) == "{\n  \"a\": 1,\n  \"c\": 3\n}")
        #expect(try JSONCText.removing(at: ["c"], in: text) == "{\n  \"a\": 1,\n  \"b\": 2\n}")

        for key in ["a", "b", "c"] {
            let updated = try JSONCText.removing(at: [key], in: text)
            let values = try topLevelObject(of: updated)
            #expect(values.count == 2, "removing \(key) left \(values.count) keys")
        }

        #expect(try JSONCText.removing(at: ["a"], in: "{\n  \"a\": 1\n}") == "{}")
        #expect(try JSONCText.removing(at: ["a"], in: "{ \"a\": 1 }") == "{}")
        #expect(try JSONCText.removing(at: ["a", "b"], in: "{\n  \"a\": {\n    \"b\": 1,\n    \"c\": 2\n  }\n}")
            == "{\n  \"a\": {\n    \"c\": 2\n  }\n}")
    }

    @Test func removingKeepsUnrelatedCommentsAndIgnoresAbsentKeys() throws {
        let text = """
        {
          // about a
          "a": 1,
          "b": 2,
          "c": 3
        }
        """

        #expect(try JSONCText.removing(at: ["b"], in: text) == """
        {
          // about a
          "a": 1,
          "c": 3
        }
        """)
        #expect(try JSONCText.removing(at: ["missing"], in: text) == text)
        #expect(try JSONCText.removing(at: ["a", "deep"], in: text) == text)
    }

    // MARK: - Round trip

    @Test func applyingSeveralSettingsToARealisticFileKeepsItParseableAndCommented() throws {
        var document = #"""
        // Soprano settings
        {
          // Appearance
          "theme": "gruvbox-dark",
          "fontSize": 13,

          "keybindings": {
            "prefixKey": "a",
            /* milliseconds */
            "prefixTimeoutMs": 1500,
          },

          "projects": [
            "~/git/soprano",
          ],
        }
        """#

        let edits: [(String, (String) throws -> String)] = [
            ("fontSize", { try JSONCText.setting(15, at: ["fontSize"], in: $0) }),
            ("prefixKey", { try JSONCText.setting("b", at: ["keybindings", "prefixKey"], in: $0) }),
            ("prefixTimeoutMs", { try JSONCText.setting(2000, at: ["keybindings", "prefixTimeoutMs"], in: $0) }),
            ("repeatable", { try JSONCText.setting(true, at: ["keybindings", "repeatable"], in: $0) }),
            ("projects", { try JSONCText.setting(["~/git/soprano", "~/git/edi"], at: ["projects"], in: $0) }),
            ("animations", { try JSONCText.setting("linear", at: ["animations", "curve"], in: $0) }),
        ]

        for (label, edit) in edits {
            document = try edit(document)
            let values = try topLevelObject(of: document)
            #expect(values.isEmpty == false, "\(label) produced an unparseable document")
            #expect(document.contains("// Soprano settings"), "\(label) dropped the header comment")
            #expect(document.contains("/* milliseconds */"), "\(label) dropped a block comment")
        }

        let values = try topLevelObject(of: document)
        #expect(values["fontSize"] as? Int == 15)
        #expect(values["theme"] as? String == "gruvbox-dark")
        #expect(values["projects"] as? [String] == ["~/git/soprano", "~/git/edi"])
        let keybindings = values["keybindings"] as? [String: Any]
        #expect(keybindings?["prefixKey"] as? String == "b")
        #expect(keybindings?["prefixTimeoutMs"] as? Int == 2000)
        #expect(keybindings?["repeatable"] as? Bool == true)
        #expect((values["animations"] as? [String: Any])?["curve"] as? String == "linear")

        document = try JSONCText.removing(at: ["theme"], in: document)
        let afterRemoval = try topLevelObject(of: document)
        #expect(afterRemoval["theme"] == nil)
        #expect(afterRemoval["fontSize"] as? Int == 15)
        #expect(document.contains("// Soprano settings"))
        #expect(document.contains("// Appearance"))
    }

    // MARK: - Helpers

    private struct Sample: Codable, Equatable {
        let name: String
        let count: Int
        let flags: [String]
    }

    private func topLevelObject(of text: String) throws -> [String: Any] {
        let data = try JSONCText.strictJSONData(from: text)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return parsed as? [String: Any] ?? [:]
    }

    private func parseError(from text: String) -> JSONCText.ParseError? {
        do {
            _ = try JSONCText.strictJSONData(from: text)
            return nil
        } catch let error as JSONCText.ParseError {
            return error
        } catch {
            return nil
        }
    }
}
