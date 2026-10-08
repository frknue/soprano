import AppKit
import Testing
@testable import Soprano

struct CodeSyntaxHighlighterTests {
    @Test func swiftCodeIsSplitIntoKeywordsStringsCallsTypesAndComments() {
        let tokens = highlighted(
            """
            @MainActor
            func greet(_ name: String) -> Int {
                print("hi // not a comment") // done
                return 42
            }
            """,
            .swift
        )

        #expect(tokens.contains { $0 == ("@MainActor", .attribute) })
        #expect(tokens.contains { $0 == ("func", .keyword) })
        #expect(tokens.contains { $0 == ("greet", .function) })
        #expect(tokens.contains { $0 == ("String", .type) })
        #expect(tokens.contains { $0 == ("\"hi // not a comment\"", .string) })
        #expect(tokens.contains { $0 == ("// done", .comment) })
        #expect(tokens.contains { $0 == ("42", .number) })
        #expect(!tokens.contains { $0.kind == .comment && $0.text.contains("not a comment") })
    }

    @Test func blockCommentsAndTripleQuotedStringsSpanLines() {
        let c = highlighted("int a; /* one\ntwo */ int b;", .c)
        #expect(c.contains { $0 == ("/* one\ntwo */", .comment) })
        #expect(c.filter { $0.kind == .keyword }.map(\.text) == ["int", "int"])

        let python = highlighted("x = \"\"\"first\nsecond\"\"\"\ny = 1  # note", .python)
        #expect(python.contains { $0 == ("\"\"\"first\nsecond\"\"\"", .string) })
        #expect(python.contains { $0 == ("# note", .comment) })
    }

    @Test func anUnclosedRustTickIsALifetimeNotAString() {
        let tokens = highlighted("fn f<'a>(s: &'a str) -> char { 'x' }", .rust)

        #expect(!tokens.contains { $0.kind == .string && $0.text.hasPrefix("'a") })
        #expect(tokens.filter { $0.kind == .string }.map(\.text) == ["'x'"])
        #expect(highlighted(#"let c = '\''; let e = '\u{1F600}';"#, .rust).filter { $0.kind == .string }.map(\.text)
            == [#"'\''"#, #"'\u{1F600}'"#])
    }

    @Test func rawStringsKeepBackslashesAndShellStringsMaySpanLines() {
        let go = highlighted("a := `C:\\dir\\`\nb := 1", .go)
        #expect(go.contains { $0 == ("`C:\\dir\\`", .string) })
        #expect(go.contains { $0 == ("1", .number) })

        let shell = highlighted("awk 'BEGIN {\n  print $1\n}' file", .shell)
        #expect(shell.contains { $0 == ("'BEGIN {\n  print $1\n}'", .string) })
        #expect(highlighted(#"echo 'a\' b"#, .shell).contains { $0 == (#"'a\'"#, .string) })
    }

    @Test func aHashOnlyStartsAShellCommentAtAWordBoundary() {
        let tokens = highlighted("echo $# ${HOME}#x # real", .shell)

        #expect(tokens.contains { $0 == ("# real", .comment) })
        #expect(tokens.filter { $0.kind == .comment }.count == 1)
        #expect(tokens.contains { $0 == ("${HOME}", .attribute) })
    }

    @Test func plainCSSURLsAreNotComments() {
        let tokens = highlighted("a { background: url(http://example.com/x.png); }", .css)

        #expect(!tokens.contains { $0.kind == .comment })
        #expect(highlighted("$x: 1; // note", .scss).contains { $0 == ("// note", .comment) })
    }

    @Test func jsonKeysAreKeysAndValuesAreStrings() {
        let tokens = highlighted(#"{"name": "soprano", "ok": true}"#, .json)

        #expect(tokens.contains { $0 == (#""name""#, .key) })
        #expect(tokens.contains { $0 == (#""soprano""#, .string) })
        #expect(tokens.contains { $0 == ("true", .keyword) })
    }

    @Test func yamlAndTomlNamesAreKeysButValuesWithColonsAreNot() {
        let yaml = highlighted("name: soprano\nurl: http://x\nitems:\n  - id: 1 # c\n", .yaml)
        #expect(yaml.filter { $0.kind == .key }.map(\.text) == ["name", "url", "items", "id"])
        #expect(yaml.contains { $0 == ("# c", .comment) })

        let toml = highlighted("[package]\nname = \"x\"\n", .toml)
        #expect(toml.contains { $0 == ("[package]", .heading) })
        #expect(toml.contains { $0 == ("name", .key) })
    }

    @Test func markdownColorsHeadingsListsAndCode() {
        let tokens = highlighted("# Title\n- item with `code`\n```swift\nlet a = 1\n```\nafter", .markdown)

        #expect(tokens.contains { $0 == ("# Title", .heading) })
        #expect(tokens.contains { $0 == ("-", .keyword) })
        #expect(tokens.contains { $0 == ("`code`", .string) })
        #expect(tokens.contains { $0 == ("let a = 1", .string) })
        #expect(!tokens.contains { $0.text == "after" })
    }

    @Test func markupColorsTagsAttributesValuesAndComments() {
        let tokens = highlighted(#"<!-- c --><a href="/x">don't</a>"#, .markup)

        #expect(tokens.map(\.text) == ["<!-- c -->", "a", "href", #""/x""#, "a"])
        #expect(tokens.map(\.kind) == [.comment, .tag, .key, .string, .tag])
    }

    @Test func rangesAreUTF16OffsetsSoNonASCIITextStaysAligned() throws {
        let text = "let ü = \"✓\" // ok"
        let tokens = CodeSyntaxHighlighter.tokens(in: text, language: .swift)
        let comment = try #require(tokens.first { $0.kind == .comment })

        #expect((text as NSString).substring(with: comment.range) == "// ok")
    }

    @Test func filesAreMatchedByNameThenExtension() {
        #expect(CodeLanguage.forFile(named: "Makefile")?.id == "makefile")
        #expect(CodeLanguage.forFile(named: "Dockerfile.dev")?.id == "dockerfile")
        #expect(CodeLanguage.forFile(named: ".env.local")?.id == "dotenv")
        #expect(CodeLanguage.forFile(named: "App.TSX")?.id == "typescript")
        #expect(CodeLanguage.forFile(named: "notes.txt") == nil)
        #expect(CodeLanguage.forFile(named: "README") == nil)
    }

    private func highlighted(_ text: String, _ language: CodeLanguage) -> [(text: String, kind: SyntaxTokenKind)] {
        let string = text as NSString
        return CodeSyntaxHighlighter.tokens(in: text, language: language).map {
            (string.substring(with: $0.range), $0.kind)
        }
    }
}
