import AppKit
import Testing
@testable import Soprano

@MainActor
struct EditorCatalogTests {
    private func installed(_ bundleIDs: Set<String>) -> [InstalledEditor] {
        EditorCatalog.installed { bundleIDs.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil }
    }

    @Test func installedEditorsAreListedCursorVSCodeZedXcodeWithFinderLast() {
        let editors = installed(["com.apple.finder", "dev.zed.Zed", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"])
        #expect(editors.map(\.id) == ["cursor", "vscode", "zed", "xcode", "finder"])
    }

    @Test func anAlternateBundleCountsAsTheSameEditor() {
        let editors = installed(["dev.zed.Zed-Preview", "com.jetbrains.pycharm.ce"])
        #expect(editors.map(\.id) == ["zed", "pycharm"])
        #expect(editors.first?.appURL.lastPathComponent == "dev.zed.Zed-Preview.app")
    }

    @Test func theSessionChoiceBeatsTheSettingWhichBeatsTheFirstInstalled() {
        let editors = installed(["com.microsoft.VSCode", "dev.zed.Zed", "com.apple.finder"])
        #expect(EditorCatalog.preferred(in: editors, chosen: nil, setting: nil)?.id == "vscode")
        #expect(EditorCatalog.preferred(in: editors, chosen: nil, setting: "zed")?.id == "zed")
        #expect(EditorCatalog.preferred(in: editors, chosen: "finder", setting: "zed")?.id == "finder")
    }

    @Test func choicesThatAreNotInstalledFallThrough() {
        let editors = installed(["dev.zed.Zed", "com.apple.finder"])
        #expect(EditorCatalog.preferred(in: editors, chosen: "cursor", setting: "xcode")?.id == "zed")
        #expect(EditorCatalog.preferred(in: [], chosen: nil, setting: "zed") == nil)
    }
}
