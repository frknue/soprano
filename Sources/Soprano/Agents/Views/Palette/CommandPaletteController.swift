import AppKit
import SopranoAgentsCore

/// T3 Code's command palette (⌘K): a 576 pt glass card near the top of the window over a dimmed
/// backdrop, a search field ("Search commands, projects, and threads..."), grouped results and a
/// key-hint footer. ↑↓ move, ↩ runs, Esc closes (or leaves a submenu), ⌘1–9 pick a visible row.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    static let width: CGFloat = 576
    static let maxHeight: CGFloat = 420
    static let inputHeight: CGFloat = 48
    static let footerHeight: CGFloat = 41
    static let placeholder = "Search commands, projects, and threads..."

    private let engine: AgentEngine
    private let state: WorkspaceState
    private weak var parent: NSWindow?
    private let source: PaletteSource

    private let window = OverlayWindow()
    private let card = OverlayCardView(surface: .popover, radius: Radius.xl)
    private let searchIcon = GhostIconButton(symbol: Icon.search, size: 24, symbolSize: 15)
    let field = NSTextField()
    private let list = PaletteListView()
    private let scrollView = NSScrollView()
    private let footer = PaletteFooterView()
    private let empty = ThemedLabel("", size: Typography.bodySize) { $0.mutedForeground }
    private var listHeight: NSLayoutConstraint?

    private(set) var submenu: PaletteSubmenu?
    private(set) var groups: [PaletteGroup] = []
    /// Flat index of the highlighted entry.
    private(set) var highlighted = 0

    var entries: [PaletteEntry] { groups.flatMap(\.entries) }

    init(engine: AgentEngine, state: WorkspaceState, parent: NSWindow, source: PaletteSource) {
        self.engine = engine
        self.state = state
        self.parent = parent
        self.source = source
        super.init()
    }

    // MARK: - Opening

    /// Opens the palette over the context's window, or closes it when it is already open.
    static func toggle(in context: CommandContext) {
        guard let window = context.window, let engine = context.engine, let state = context.state else { return }
        if let open = OverlayWindow.topmost(over: window), open.owner is CommandPaletteController {
            open.dismiss()
            return
        }
        let settings = SettingsCenter.shared
        let source = PaletteSource.make(
            commands: CommandRegistry.shared.commands,
            context: context,
            keycaps: { settings.keycaps(for: $0) },
            engine: engine,
            now: engine.environment.now()
        )
        CommandPaletteController(engine: engine, state: state, parent: window, source: source).present()
    }

    private func present() {
        guard let parent else { return }
        window.owner = self
        buildViews()
        reload()
        window.backdrop.onClick = { [weak self] in self?.close() }
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.present(over: parent, focus: field)
    }

    private func buildViews() {
        let backdrop = window.backdrop
        card.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(card)
        let content = card.content

        searchIcon.isEnabled = true
        searchIcon.onClick = { [weak self] in
            guard let self, submenu != nil else { return }
            popSubmenu()
        }
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = Typography.ui(15)
        field.delegate = self
        field.setAccessibilityLabel("Command palette")
        applyFieldPalette(PaletteCenter.shared.palette)
        PaletteCenter.shared.addObserver(self) { [weak self] palette in self?.applyFieldPalette(palette) }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = list
        list.onClick = { [weak self] index in self?.run(index) }
        list.onHover = { [weak self] index in self?.setHighlighted(index, scroll: false) }

        empty.alignment = .center
        empty.isHidden = true

        for view in [searchIcon, field, scrollView, footer, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        self.listHeight = listHeight
        let maxTop = card.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 0)
        let width = card.widthAnchor.constraint(equalToConstant: Self.width)
        width.priority = .overlayPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            width,
            card.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -32),
            maxTop,

            searchIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchIcon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inputHeight),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listHeight,

            empty.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        // T3 Code's viewport: `sm:py-[10vh]`.
        maxTop.constant = max(16, (parent?.frame.height ?? 800) * 0.1)
        topConstraint = maxTop
    }

    private var topConstraint: NSLayoutConstraint?

    private func applyFieldPalette(_ palette: Palette) {
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: submenu?.placeholder ?? Self.placeholder, attributes: [
            .foregroundColor: palette.placeholder,
            .font: field.font ?? Typography.ui(15),
        ])
    }

    // MARK: - Results

    private func reload() {
        groups = PaletteSearch.groups(query: field.stringValue, submenu: submenu, source: source)
        highlighted = 0
        let width = min(Self.width, (parent?.frame.width ?? Self.width) - 32)
        list.update(groups: groups, highlighted: highlighted, width: width)
        let available = min(Self.maxHeight, (parent?.frame.height ?? 800) - (topConstraint?.constant ?? 0) - 32)
            - Self.inputHeight - Self.footerHeight
        let emptyHeight: CGFloat = 92
        listHeight?.constant = groups.isEmpty ? emptyHeight : min(list.frame.height, max(emptyHeight, available))
        empty.isHidden = !groups.isEmpty
        empty.stringValue = field.stringValue.hasPrefix(">") ? "No matching actions." : "No matching commands, projects, or threads."
        list.scroll(.zero)
        searchIcon.setSymbol(submenu == nil ? Icon.search : "arrow.left", size: 15)
        searchIcon.toolTip = submenu == nil ? nil : "Back"
        footer.update(showsBack: submenu != nil)
        applyFieldPalette(PaletteCenter.shared.palette)
    }

    private func setHighlighted(_ index: Int, scroll: Bool) {
        let count = entries.count
        guard count > 0 else { return }
        highlighted = min(max(0, index), count - 1)
        list.setHighlighted(highlighted)
        if scroll { list.scrollHighlightedIntoView() }
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let stroke = KeyStroke(event: event), !stroke.option else { return false }
        let plain = !stroke.ctrl && !stroke.meta
        switch stroke.key {
        case "\u{F701}" where plain, "n" where stroke.ctrl && !stroke.meta:
            setHighlighted(highlighted + 1, scroll: true)
            return true
        case "\u{F700}" where plain, "p" where stroke.ctrl && !stroke.meta:
            setHighlighted(highlighted - 1, scroll: true)
            return true
        case "\r" where plain:
            run(highlighted)
            return true
        case "\u{1B}" where plain:
            if submenu != nil { popSubmenu() } else { close() }
            return true
        case "\u{7F}" where plain && submenu != nil && field.stringValue.isEmpty:
            popSubmenu()
            return true
        case "k" where stroke.meta && !stroke.ctrl && !stroke.shift:
            close()
            return true
        default:
            if stroke.meta, !stroke.ctrl, !stroke.shift, let digit = Int(stroke.key), (1...9).contains(digit) {
                if digit - 1 < entries.count { run(digit - 1) }
                return true
            }
            return false
        }
    }

    // MARK: - Running

    private func run(_ index: Int) {
        let entries = entries
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        switch entry.kind {
        case let .submenu(menu):
            submenu = menu
            field.stringValue = ""
            reload()
        case let .command(id):
            let controller = parent?.windowController as? MainWindowController
            close()
            controller?.perform(id)
        case let .thread(id):
            close()
            state.select(.thread(id))
        case let .project(id):
            let controller = parent?.windowController as? MainWindowController
            close()
            state.select(.draft(projectID: id))
            controller?.perform("composer.focus")
        case let .settings(page):
            let parent = parent
            close()
            if let parent { SettingsController.present(page: page, engine: engine, over: parent) }
        }
    }

    private func popSubmenu() {
        submenu = nil
        field.stringValue = ""
        reload()
    }

    func close() {
        window.dismiss()
    }
}

// MARK: - List

/// The result list: group labels (`px-2 py-1.5 text-xs font-medium text-muted-foreground`) and
/// rows laid out by frame in a flipped document view.
final class PaletteListView: NSView {
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private var rows: [PaletteRowView] = []

    override var isFlipped: Bool { true }

    func update(groups: [PaletteGroup], highlighted: Int, width: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        rows = []
        var y: CGFloat = 8
        var index = 0
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 { y += 6 }
            let label = ThemedLabel(group.title, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
            label.frame = NSRect(x: 16, y: y + 6, width: width - 32, height: 16)
            addSubview(label)
            y += 28
            for entry in group.entries {
                let row = PaletteRowView(entry: entry, index: index)
                let height = entry.subtitle == nil ? PaletteRowView.singleHeight : PaletteRowView.doubleHeight
                row.frame = NSRect(x: 8, y: y, width: width - 16, height: height)
                row.onClick = { [weak self] in self?.onClick?(row.index) }
                row.onHover = { [weak self] in self?.onHover?(row.index) }
                row.isHighlighted = index == highlighted
                addSubview(row)
                rows.append(row)
                y += height
                index += 1
            }
        }
        setFrameSize(NSSize(width: width, height: groups.isEmpty ? 0 : y + 8))
    }

    func setHighlighted(_ index: Int) {
        for row in rows { row.isHighlighted = row.index == index }
    }

    func scrollHighlightedIntoView() {
        guard let row = rows.first(where: \.isHighlighted) else { return }
        scrollToVisible(row.frame.insetBy(dx: 0, dy: -8))
    }
}

/// One palette row (`min-h-8 rounded-sm px-2 py-1.5 gap-2`): icon, title with matched letters
/// in medium weight, optional description line, trailing time, shortcut keycaps, submenu chevron.
final class PaletteRowView: InteractiveView {
    static let singleHeight: CGFloat = 32
    static let doubleHeight: CGFloat = 46

    let index: Int
    let entry: PaletteEntry
    var onHover: (() -> Void)?
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { applyPalette(palette) } }
    }

    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = ThemedLabel("", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) }
    private let trailing = ThemedLabel("", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) }
    private let accessories = NSStackView()

    init(entry: PaletteEntry, index: Int) {
        self.entry = entry
        self.index = index
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm + 2
        iconView.image = NSImage.symbol(entry.icon, size: 14)
        iconView.imageScaling = .scaleNone
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.truncatesLastVisibleLine = true
        subtitle.stringValue = entry.subtitle ?? ""
        subtitle.isHidden = entry.subtitle == nil
        trailing.stringValue = entry.trailing ?? ""
        trailing.font = Typography.tabular(Typography.smallSize)
        trailing.isHidden = entry.trailing == nil
        accessories.orientation = .horizontal
        accessories.spacing = 4
        accessories.addArrangedSubview(trailing)
        for cap in entry.keycaps { accessories.addArrangedSubview(KbdView(cap)) }
        if entry.isSubmenu {
            let chevron = NSImageView()
            chevron.image = NSImage.symbol(Icon.chevronRight, size: 12)
            chevron.contentTintColor = PaletteCenter.shared.palette.mutedForeground.withAlphaComponent(0.7)
            accessories.addArrangedSubview(chevron)
        }
        for view in [iconView, title, subtitle, accessories] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessories.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleCenter = entry.subtitle == nil
            ? title.centerYAnchor.constraint(equalTo: centerYAnchor)
            : title.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleCenter,
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -8),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.title)
        applyPalette(palette)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?()
    }

    override func applyPalette(_ palette: Palette) {
        let fill = isHighlighted ? palette.foreground.withAlphaComponent(palette.isDark ? 0.09 : 0.06) : .clear
        layer?.backgroundColor = fill.cgColor
        iconView.contentTintColor = palette.mutedForeground
        title.attributedStringValue = Self.highlightedTitle(entry, palette: palette)
    }

    /// The title in the body font with the matched characters in medium weight and full foreground.
    static func highlightedTitle(_ entry: PaletteEntry, palette: Palette) -> NSAttributedString {
        let text = NSMutableAttributedString(string: entry.title, attributes: [
            .font: Typography.ui(Typography.bodySize),
            .foregroundColor: palette.foreground,
        ])
        guard !entry.highlights.isEmpty else { return text }
        let characters = Array(entry.title)
        var offset = 0
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(characters.count)
        for character in characters {
            utf16Offsets.append(offset)
            offset += character.utf16.count
        }
        for position in entry.highlights where position < characters.count {
            let range = NSRange(location: utf16Offsets[position], length: characters[position].utf16.count)
            text.addAttributes([.font: Typography.ui(Typography.bodySize, weight: .semibold)], range: range)
        }
        // Unmatched letters recede slightly so the match reads at a glance.
        return text
    }
}

/// `CommandFooter`: `border-t bg-foreground/[0.025] px-4 py-2.5` with ↑ ↓ Navigate, Enter Select,
/// Backspace Back (submenus) and Esc Close.
final class PaletteFooterView: PaletteView {
    private let stack = NSStackView()
    private let rule = CALayer()
    private var showsBack: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(rule)
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(showsBack: false)
        applyPalette(palette)
    }

    func update(showsBack: Bool) {
        guard showsBack != self.showsBack else { return }
        self.showsBack = showsBack
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var hints: [([String], String)] = [(["↑", "↓"], "Navigate"), (["Enter"], "Select")]
        if showsBack { hints.append((["Backspace"], "Back")) }
        hints.append((["Esc"], "Close"))
        for (keys, label) in hints {
            let group = NSStackView()
            group.orientation = .horizontal
            group.spacing = 4
            for key in keys { group.addArrangedSubview(KbdView(key)) }
            group.setCustomSpacing(6, after: group.arrangedSubviews.last!)
            group.addArrangedSubview(ThemedLabel(label, size: Typography.rowSize, weight: .medium) { $0.mutedForeground })
            stack.addArrangedSubview(group)
        }
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(0.025).cgColor
        rule.backgroundColor = palette.foreground.withAlphaComponent(0.07).cgColor
    }
}
