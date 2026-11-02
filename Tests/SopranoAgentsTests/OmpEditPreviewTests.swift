import AppKit
import Testing
@testable import SopranoAgentsCore

struct OmpEditPreviewTests {
    private func object(_ text: String) -> JSONValue? { OmpEditPreview.partialObject(text) }

    // MARK: - Partial JSON

    @Test func aCutStringValueEndsWhereTheStreamStopped() {
        let args = object(#"{"path": "/a.swift", "content": "line 1\nli"#)
        #expect(args?["path"]?.stringValue == "/a.swift")
        #expect(args?["content"]?.stringValue == "line 1\nli")
    }

    @Test func aKeyWithoutItsValueYetReadsAsNull() {
        #expect(object(#"{"path": "/a", "con"#)?["path"]?.stringValue == "/a")
        #expect(object(#"{"path": "/a", "content":"#)?["content"] == .null)
        #expect(object(#"{"path": "/a",  "#)?["path"]?.stringValue == "/a")
    }

    @Test func aCutEscapeIsDropped() {
        #expect(object(#"{"input": "a\"#)?["input"]?.stringValue == "a")
        #expect(object(#"{"input": "x\u00"#)?["input"]?.stringValue == "x")
        #expect(object(#"{"input": "x\\u00"#)?["input"]?.stringValue == #"x\u00"#)
    }

    @Test func nestedContainersClose() {
        let args = object(#"{"path": "a", "edits": [{"diff": "+a\n-b"#)
        #expect(args?["edits"]?.arrayValue?.first?["diff"]?.stringValue == "+a\n-b")
    }

    // MARK: - Code per tool

    @Test func aWriteAddsEveryLineFromTheFirst() {
        let changes = OmpEditPreview.changes(tool: "write", args: ["path": "/repo/a.txt", "content": "one\ntwo\n"]) { $0.replacingOccurrences(of: "/repo/", with: "") }
        #expect(changes == [FileChange(path: "a.txt", kind: .update, diff: "@@ -0,0 +1,2 @@\n+one\n+two")])
    }

    @Test func writesToInternalURLsCarryNoCode() {
        #expect(OmpEditPreview.changes(tool: "write", args: ["path": "xd://lsp", "content": "{}"]).isEmpty)
        #expect(OmpEditPreview.changes(tool: "write", args: ["path": "agent://all", "content": "hi"]).isEmpty)
    }

    @Test func hashlineSectionsBecomeOneFileEachWithTheirOpsAsHunks() {
        let input = "[a.swift#1A2B]\nPUT 3.=4:\n+let x = 1\n+\n[b.swift#3C4D]\nCUT 7.=9\n"
        let changes = OmpEditPreview.changes(tool: "edit", args: ["input": .string(input)])
        #expect(changes == [
            FileChange(path: "a.swift", kind: .update, diff: "@@ -0,0 +0,2 @@ PUT 3.=4:\n+let x = 1\n+"),
            FileChange(path: "b.swift", kind: .update, diff: "@@ -0,0 +0,0 @@ CUT 7.=9"),
        ])
    }

    @Test func applyPatchSectionsKeepTheirKindsAndLines() {
        let input = "*** Begin Patch\n*** Add File: new.txt\n+hello\n*** Update File: old.txt\n@@ func f()\n-a\n+b\n context\n*** End Patch"
        let changes = OmpEditPreview.changes(tool: "apply_patch", args: ["input": .string(input)])
        #expect(changes == [
            FileChange(path: "new.txt", kind: .add, diff: "@@ -0,0 +0,1 @@\n+hello"),
            FileChange(path: "old.txt", kind: .update, diff: "@@ -0,2 +0,2 @@ func f()\n-a\n+b\n context"),
        ])
    }

    @Test func replaceAndSloppyEditsRemoveTheOldTextAndAddTheNew() {
        let replace = OmpEditPreview.changes(tool: "edit", args: ["path": "a.txt", "old_string": "a\nb", "new_string": "c"])
        #expect(replace == [FileChange(path: "a.txt", kind: .update, diff: "@@ -0,2 +0,1 @@\n-a\n-b\n+c")])

        let sloppy = OmpEditPreview.changes(tool: "edit", args: ["input": "*** Edit File: x.txt\n*** Find\nold\n*** Replace\nnew"])
        #expect(sloppy == [FileChange(path: "x.txt", kind: .update, diff: "@@ -0,1 +0,1 @@\n-old\n+new")])
    }

    @Test func patchEditsRenameAndCreate() {
        let changes = OmpEditPreview.changes(tool: "edit", args: [
            "path": "a.txt",
            "edits": [["op": "update", "rename": "b.txt", "diff": "@@ -1,1 +1,1 @@\n-x\n+y"]],
        ])
        #expect(changes == [FileChange(path: "a.txt", kind: .move, movePath: "b.txt", diff: "@@ -0,1 +0,1 @@\n-x\n+y")])
    }

    @Test func argumentsWithoutCodeYetGiveNothing() {
        #expect(OmpEditPreview.changes(tool: "edit", args: ["path": "a.txt"]).isEmpty)
        #expect(OmpEditPreview.changes(tool: "write", args: ["path": "a.txt"]).isEmpty)
        #expect(OmpEditPreview.changes(tool: "bash", args: ["command": "ls"]).isEmpty)
    }
}
