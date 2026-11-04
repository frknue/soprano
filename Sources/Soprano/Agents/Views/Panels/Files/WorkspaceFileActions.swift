import AppKit

/// What the Files explorer and file tabs do with a workspace file outside the app: Finder,
/// the configured editor, the pasteboard. Only `NSWorkspace` opens, never a process.
@MainActor
enum WorkspaceFileActions {
    /// Selects `url` in a Finder window.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens `url` in the editor "Open in" uses (the session's choice, else `editor.app`, else
    /// the first installed). Without one, or when that is Finder, the file is revealed in Finder:
    /// opening it in its default app would run executables and scripts.
    static func openInEditor(_ url: URL) {
        let editor = EditorCatalog.preferred(
            in: EditorCatalog.installedOnThisMac(), chosen: EditorChoice.chosenID,
            setting: SettingsCenter.shared.settings.editorApp
        )
        guard let editor, editor.id != "finder" else {
            reveal(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// SF Symbol for a file row, by extension.
    static func symbol(forFileNamed name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "ico", "svg": return "photo"
        case "swift": return "swift"
        default: return "doc.text"
        }
    }
}
