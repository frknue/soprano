import AppKit
import UniformTypeIdentifiers

enum MarkdownFilePicker {
    @MainActor
    static func begin(
        relativeTo window: NSWindow,
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = markdownTypes
        panel.prompt = "Open"
        panel.message = "Choose a Markdown file to open in a live reader."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let fileURL = panel.url else { return }
            completion(fileURL.standardizedFileURL)
        }
    }

    static func isMarkdown(_ fileURL: URL) -> Bool {
        let fileExtension = fileURL.pathExtension.lowercased()
        return fileExtension == "md" || fileExtension == "markdown"
    }

    private static var markdownTypes: [UTType] {
        ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }
}
