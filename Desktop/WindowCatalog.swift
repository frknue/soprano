import AppKit
@preconcurrency import ScreenCaptureKit
import ApplicationServices

@MainActor
struct DesktopWindow {
    let source: SCWindow
    let appName: String
    let title: String
    var id: CGWindowID { source.windowID }
    var processID: pid_t { source.owningApplication!.processID }
    let searchText: String
}

@MainActor
final class WindowCatalog {
    var screenPermission: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityPermission: Bool { AXIsProcessTrusted() }

    func requestPermissions() {
        if !screenPermission { _ = CGRequestScreenCaptureAccess() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func windows() async throws -> [DesktopWindow] {
        guard screenPermission else {
            throw DesktopError.message("Screen Recording access is required for real window previews. Choose Permissions in the menu, allow Soprano Desktop, then relaunch it.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let owner = window.owningApplication,
                  owner.processID != ProcessInfo.processInfo.processIdentifier,
                  window.windowLayer == 0,
                  window.frame.width >= 120, window.frame.height >= 80,
                  NSRunningApplication(processIdentifier: owner.processID)?.activationPolicy == .regular else { return nil }
            let name = owner.applicationName
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DesktopWindow(source: window, appName: name, title: title.isEmpty ? name : title,
                searchText: name + " " + title)
        }
    }

    func snapshotDesktop(to url: URL) async throws {
        guard screenPermission else { throw DesktopError.message("Screen Recording access is required for a desktop snapshot") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenID = (Desktop.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw DesktopError.message("No display is available for capture")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Desktop.writePNG(NSBitmapImageRep(cgImage: image), to: url)
    }

    func preview(_ window: DesktopWindow) async throws -> NSImage {
        let configuration = SCStreamConfiguration()
        let scale = min(1, 640 / max(window.source.frame.width, 1))
        configuration.width = max(1, Int(window.source.frame.width * scale))
        configuration.height = max(1, Int(window.source.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window.source)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Desktop.image(image)
    }

    func focus(_ window: DesktopWindow) throws {
        guard accessibilityPermission else {
            throw DesktopError.message("Accessibility access is required to select a window. Allow Soprano Desktop in System Settings → Privacy & Security → Accessibility.")
        }
        guard let application = NSRunningApplication(processIdentifier: window.processID), !application.isTerminated else {
            throw DesktopError.message("This app has closed. Refresh the overview.")
        }
        let app = AXUIElementCreateApplication(window.processID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            throw DesktopError.message("\(window.appName) does not expose accessible windows (\(result.rawValue)).")
        }
        let candidates = windows.compactMap { element -> (AXUIElement, CGFloat)? in
            let title = stringAttribute(element, kAXTitleAttribute)
            guard let frame = windowFrame(element) else { return nil }
            let distance = abs(frame.minX - window.source.frame.minX) + abs(frame.minY - window.source.frame.minY)
                + abs(frame.width - window.source.frame.width) + abs(frame.height - window.source.frame.height)
            let titleMatches = title == window.title || (title?.isEmpty == true && window.title == window.appName)
            guard titleMatches || distance < 8 else { return nil }
            return (element, distance + (titleMatches ? 0 : 1000))
        }.sorted { $0.1 < $1.1 }
        guard let selected = candidates.first,
              candidates.count == 1 || candidates[1].1 > selected.1 + 1 else {
            throw DesktopError.message("The selected window changed or cannot be uniquely identified. Refresh the overview.")
        }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(selected.0, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            let unminimize = AXUIElementSetAttributeValue(selected.0, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard unminimize == .success else { throw DesktopError.message("Could not restore this window (\(unminimize.rawValue)).") }
        }
        guard application.activate(options: []) else { throw DesktopError.message("Could not activate \(window.appName).") }
        let raise = AXUIElementPerformAction(selected.0, kAXRaiseAction as CFString)
        guard raise == .success else { throw DesktopError.message("Could not raise this window (\(raise.rawValue)).") }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func windowFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
