import AppKit

// Compile the terminal app's existing Theme, RetroChrome and color utility into
// this independent executable. Both apps therefore use the same design source.
enum SopranoResources {
    static let bundle = Bundle.main
}

@MainActor
enum Desktop {
    static let theme = AppTheme.missionControl
    static let bundleID = "com.soprano.desktop"
    static let commandNotification = Notification.Name("com.soprano.desktop.command")
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Soprano Desktop", isDirectory: true)
    static let appURL = URL(fileURLWithPath: "/Applications/Soprano Desktop.app")
    static let shortcut = "⌃⌥Space"

    static var screen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    static func label(_ text: String, color: NSColor? = nil, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.setRetroText(text, color: color ?? theme.colors.textPrimary, size: size)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func image(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func writePNG(_ image: NSBitmapImageRep, to url: URL) throws {
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw DesktopError.message("Could not encode image at \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DesktopError.message("Could not capture the desktop panel")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try writePNG(bitmap, to: url)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DesktopError.message(String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(executable) failed")
        }
        return output
    }

    static func report(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

@MainActor
final class ConsolePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class ConsoleBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors = Desktop.theme.colors
        colors.bgBase.setFill()
        dirtyRect.fill()
        colors.borderStrong.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }
}
