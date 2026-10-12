import AppKit

@MainActor
final class OverviewController: NSObject, NSTextFieldDelegate {
    private let catalog: WindowCatalog
    private let panel = ConsolePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let root = ConsoleBackground()
    private let search = NSTextField()
    private let status = Desktop.label("", color: Desktop.theme.colors.textMuted)
    private let count = Desktop.label("", color: Desktop.theme.colors.accent)
    private let scroll = NSScrollView()
    private let document = FlippedDocumentView()
    private var windows: [DesktopWindow] = []
    private var filtered: [DesktopWindow] = []
    private var cards: [CGWindowID: WindowCard] = [:]
    private var selectedID: CGWindowID?
    private var columns = 1
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    var onPermissions: (() -> Void)?

    init(catalog: WindowCatalog) {
        self.catalog = catalog
        super.init()
        panel.title = "Soprano Window Overview"
        panel.isOpaque = true
        panel.backgroundColor = Desktop.theme.colors.bgBase
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = root
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        build()
    }

    var isVisible: Bool { panel.isVisible }
    var visibleWindowIDs: [CGWindowID] { filtered.map(\.id) }

    func toggle() {
        if panel.isVisible { hide(); return }
        show()
    }

    func show() {
        guard let screen = Desktop.screen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let frame = screen.visibleFrame.insetBy(dx: 28, dy: 30)
        panel.setFrame(frame, display: false)
        layout()
        search.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - 12))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.alphaValue = 1 }
        refresh()
    }

    func hide(restoreFocus: Bool = true) {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        panel.orderOut(nil)
        windows.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        for card in cards.values { card.removeFromSuperview() }
        cards.removeAll(keepingCapacity: true)
        selectedID = nil
        if restoreFocus, let previousApp, previousApp.bundleIdentifier != Desktop.bundleID {
            _ = previousApp.activate(options: [])
        }
        previousApp = nil
    }

    func refresh() {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        status.setRetroText("reading open windows…", color: Desktop.theme.colors.textMuted)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await catalog.windows()
                guard !Task.isCancelled, current == generation, panel.isVisible else { return }
                windows = result
                for card in cards.values { card.removeFromSuperview() }
                cards.removeAll(keepingCapacity: true)
                for window in windows {
                    let card = WindowCard(window: window)
                    card.onSelect = { [weak self] id in self?.activate(id) }
                    cards[window.id] = card
                    document.addSubview(card)
                }
                filter()
                for window in windows {
                    guard !Task.isCancelled, current == generation, panel.isVisible else { return }
                    do {
                        let image = try await catalog.preview(window)
                        guard current == generation, !Task.isCancelled else { return }
                        cards[window.id]?.preview = image
                    } catch {
                        guard current == generation, !Task.isCancelled else { return }
                        cards[window.id]?.previewError = error.localizedDescription
                    }
                }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                status.setRetroText(error.localizedDescription, color: Desktop.theme.colors.accentStrong)
                status.toolTip = error.localizedDescription
            }
        }
    }

    func snapshot(to url: URL) throws {
        guard panel.isVisible else { throw DesktopError.message("Open the overview before taking its snapshot") }
        try Desktop.snapshot(root, to: url)
    }

    private func build() {
        let colors = Desktop.theme.colors
        root.addSubview(Desktop.label("window overview", size: 22))
        root.subviews[0].identifier = NSUserInterfaceItemIdentifier("heading")
        let stripe = RetroStripeView(layout: .slanted, colors: colors.stripe)
        stripe.identifier = NSUserInterfaceItemIdentifier("stripe")
        root.addSubview(stripe)
        root.addSubview(count)
        search.placeholderString = "type to filter by application or window title"
        search.font = RetroFont.body(14)
        search.textColor = colors.textPrimary
        search.backgroundColor = colors.bgRaised
        search.isBezeled = false
        search.focusRingType = .none
        search.delegate = self
        search.wantsLayer = true
        search.layer?.borderWidth = 1
        search.layer?.borderColor = colors.borderStrong.cgColor
        search.setAccessibilityLabel("Filter open windows")
        root.addSubview(search)
        let close = RetroButton(title: "esc / close", theme: Desktop.theme, target: self, action: #selector(closeOverview))
        close.identifier = NSUserInterfaceItemIdentifier("close")
        root.addSubview(close)
        let access = RetroButton(title: "permissions", theme: Desktop.theme, target: self, action: #selector(permissions))
        access.identifier = NSUserInterfaceItemIdentifier("permissions")
        root.addSubview(access)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        root.addSubview(scroll)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        root.addSubview(status)
    }

    private func layout() {
        let size = panel.frame.size
        root.frame = NSRect(origin: .zero, size: size)
        root.subviews.first { $0.identifier?.rawValue == "stripe" }?.frame = NSRect(x: 26, y: size.height - 61, width: 34, height: 29)
        root.subviews.first { $0.identifier?.rawValue == "heading" }?.frame = NSRect(x: 76, y: size.height - 59, width: 430, height: 32)
        count.frame = NSRect(x: 515, y: size.height - 51, width: 240, height: 20)
        root.subviews.first { $0.identifier?.rawValue == "close" }?.frame = NSRect(x: size.width - 172, y: size.height - 55, width: 144, height: 24)
        search.frame = NSRect(x: 28, y: size.height - 104, width: size.width - 56, height: 30)
        scroll.frame = NSRect(x: 28, y: 64, width: size.width - 56, height: size.height - 184)
        status.frame = NSRect(x: 28, y: 17, width: size.width - 235, height: 36)
        root.subviews.first { $0.identifier?.rawValue == "permissions" }?.frame = NSRect(x: size.width - 180, y: 22, width: 152, height: 24)
    }

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = windows.filter { query.isEmpty || $0.searchText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
        columns = max(1, Int((scroll.contentSize.width + 16) / 296))
        let width = (scroll.contentSize.width - CGFloat(columns - 1) * 16) / CGFloat(columns)
        let height = min(245, width * 0.62 + 57)
        let rows = (filtered.count + columns - 1) / columns
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(rows) * (height + 16)))
        for card in cards.values { card.isHidden = true }
        for (index, window) in filtered.enumerated() {
            guard let card = cards[window.id] else { continue }
            card.isHidden = false
            card.frame = NSRect(x: CGFloat(index % columns) * (width + 16), y: CGFloat(index / columns) * (height + 16), width: width, height: height)
            card.selected = window.id == selectedID
        }
        count.setRetroText("\(filtered.count) / \(windows.count) windows", color: Desktop.theme.colors.accent)
        let message = filtered.isEmpty ? (windows.isEmpty ? "no capturable application windows" : "no windows match your filter")
            : "arrows / tab  navigate     return  select     ⌘r  refresh     esc  close"
        status.setRetroText(message, color: Desktop.theme.colors.textMuted)
        status.toolTip = message
    }

    private func move(_ delta: Int, wrapping: Bool = false) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selectedID } ?? 0
        let next = wrapping ? (index + delta + filtered.count) % filtered.count : min(filtered.count - 1, max(0, index + delta))
        selectedID = filtered[next].id
        for card in cards.values { card.selected = card.representedWindow.id == selectedID }
        if let selectedID, let card = cards[selectedID] { document.scrollToVisible(card.frame) }
    }

    private func activate(_ id: CGWindowID) {
        guard let window = filtered.first(where: { $0.id == id }) else { return }
        do { try catalog.focus(window); hide(restoreFocus: false) }
        catch {
            status.setRetroText(error.localizedDescription, color: Desktop.theme.colors.danger)
            status.toolTip = error.localizedDescription
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" { refresh(); return true }
        switch event.keyCode {
        case 123: move(-1)
        case 124: move(1)
        case 125: move(columns)
        case 126: move(-columns)
        case 48: move(event.modifierFlags.contains(.shift) ? -1 : 1, wrapping: true)
        case 36, 76: if let selectedID { activate(selectedID) }
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch NSStringFromSelector(command) {
        case "moveLeft:": move(-1)
        case "moveRight:": move(1)
        case "moveDown:": move(columns)
        case "moveUp:": move(-columns)
        case "insertTab:": move(1, wrapping: true)
        case "insertBacktab:": move(-1, wrapping: true)
        case "insertNewline:": if let selectedID { activate(selectedID) }
        case "cancelOperation:": hide()
        default: return false
        }
        return true
    }

    @objc private func closeOverview() { hide() }
    @objc private func permissions() { onPermissions?() }
}

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class WindowCard: NSButton {
    let representedWindow: DesktopWindow
    var preview: NSImage? { didSet { needsDisplay = true } }
    var previewError: String? { didSet { toolTip = previewError; needsDisplay = true } }
    var selected = false { didSet { if oldValue != selected { needsDisplay = true } } }
    var onSelect: ((CGWindowID) -> Void)?
    private let applicationIcon: NSImage?

    init(window: DesktopWindow) {
        representedWindow = window
        applicationIcon = NSRunningApplication(processIdentifier: window.processID)?.icon
        super.init(frame: .zero)
        isBordered = false
        target = self
        action = #selector(choose)
        title = window.title
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("\(window.appName): \(window.title)")
        toolTip = window.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let colors = Desktop.theme.colors
        (selected ? colors.bgSelected : colors.bgPanel).setFill()
        bounds.fill()
        (selected ? colors.accent : colors.borderStrong).setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        edge.lineWidth = selected ? 2 : 1
        edge.stroke()
        let area = NSRect(x: 10, y: 57, width: bounds.width - 20, height: bounds.height - 67)
        if let preview {
            let scale = min(area.width / max(1, preview.size.width), area.height / max(1, preview.size.height))
            let size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
            preview.draw(in: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            applicationIcon?.draw(in: NSRect(x: area.midX - 20, y: area.midY - 8, width: 40, height: 40))
            let caption = RetroText.display(previewError == nil ? "capturing preview…" : "preview unavailable", color: colors.textMuted, tracking: 0)
            caption.draw(at: NSPoint(x: area.midX - caption.size().width / 2, y: area.midY - 32))
        }
        colors.borderSubtle.setFill()
        NSRect(x: 10, y: 49, width: bounds.width - 20, height: 1).fill()
        drawLabel(representedWindow.appName, color: selected ? colors.accent : colors.textPrimary, rect: NSRect(x: 12, y: 29, width: bounds.width - 24, height: 18))
        drawLabel(representedWindow.title, color: colors.textMuted, rect: NSRect(x: 12, y: 9, width: bounds.width - 24, height: 18))
    }

    private func drawLabel(_ text: String, color: NSColor, rect: NSRect) {
        RetroText.display(text, color: color, tracking: 0).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    @objc private func choose() { onSelect?(representedWindow.id) }
}
