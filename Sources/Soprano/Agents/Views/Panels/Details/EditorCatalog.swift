import AppKit

/// An "Open in …" target (T3 Code's `packages/contracts/src/editor.ts` list plus Xcode), found
/// on this Mac by bundle identifier.
struct EditorTarget: Equatable, Sendable {
    /// Settings id (`editor.app`): `cursor`, `vscode`, `zed`, `xcode`, `finder`, …
    var id: String
    var label: String
    /// Bundle identifiers that count as this editor, first match wins.
    var bundleIDs: [String]
}

/// An installed editor and the application bundle that opens it.
struct InstalledEditor: Equatable {
    var target: EditorTarget
    var appURL: URL

    var id: String { target.id }
    var label: String { target.label }
}

enum EditorCatalog {
    /// T3 Code's order; Finder (the file manager) is always last.
    static let all: [EditorTarget] = [
        EditorTarget(id: "cursor", label: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        EditorTarget(id: "trae", label: "Trae", bundleIDs: ["com.trae.app"]),
        EditorTarget(id: "vscode", label: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        EditorTarget(id: "vscode-insiders", label: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"]),
        EditorTarget(id: "vscodium", label: "VSCodium", bundleIDs: ["com.vscodium"]),
        EditorTarget(id: "zed", label: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        EditorTarget(id: "idea", label: "IntelliJ IDEA", bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        EditorTarget(id: "clion", label: "CLion", bundleIDs: ["com.jetbrains.CLion"]),
        EditorTarget(id: "datagrip", label: "DataGrip", bundleIDs: ["com.jetbrains.datagrip"]),
        EditorTarget(id: "goland", label: "GoLand", bundleIDs: ["com.jetbrains.goland"]),
        EditorTarget(id: "phpstorm", label: "PhpStorm", bundleIDs: ["com.jetbrains.PhpStorm"]),
        EditorTarget(id: "pycharm", label: "PyCharm", bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        EditorTarget(id: "rider", label: "Rider", bundleIDs: ["com.jetbrains.rider"]),
        EditorTarget(id: "rubymine", label: "RubyMine", bundleIDs: ["com.jetbrains.rubymine"]),
        EditorTarget(id: "rustrover", label: "RustRover", bundleIDs: ["com.jetbrains.rustrover"]),
        EditorTarget(id: "webstorm", label: "WebStorm", bundleIDs: ["com.jetbrains.WebStorm"]),
        EditorTarget(id: "xcode", label: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]),
        EditorTarget(id: "finder", label: "Finder", bundleIDs: ["com.apple.finder"]),
    ]

    /// Editors `resolve` finds an application for, in catalog order.
    static func installed(resolve: (String) -> URL?) -> [InstalledEditor] {
        all.compactMap { target in
            for bundleID in target.bundleIDs {
                if let url = resolve(bundleID) { return InstalledEditor(target: target, appURL: url) }
            }
            return nil
        }
    }

    /// Installed editors on this Mac (Launch Services lookup).
    @MainActor
    static func installedOnThisMac() -> [InstalledEditor] {
        installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// The editor "Open in" uses: the one chosen this session, else the `editor.app` setting,
    /// else the first installed. Choices that are not installed are skipped.
    static func preferred(in installed: [InstalledEditor], chosen: String?, setting: String?) -> InstalledEditor? {
        for id in [chosen, setting].compactMap({ $0 }) {
            if let match = installed.first(where: { $0.id == id }) { return match }
        }
        return installed.first
    }

    /// Opens `directory` in `editor` (Finder reveals the folder).
    @MainActor
    static func open(_ directory: String, in editor: InstalledEditor) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        if editor.id == "finder" {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Editor picked from the "Choose editor" menu; wins over the setting until the app quits.
@MainActor
enum EditorChoice {
    static var chosenID: String?
}
