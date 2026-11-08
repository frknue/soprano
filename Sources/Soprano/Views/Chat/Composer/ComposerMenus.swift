import AppKit

/// The agent's mark in the model chip and picker: omp (oh-my-pi) has no vector mark, so a heavy
/// "π" set in the system font, template-rendered (Soprano Agents' `ProviderGlyph`).
@MainActor
enum ChatAgentGlyph {
    static func image(size: CGFloat) -> NSImage {
        if let cached = cache[size] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 1.05, weight: .heavy)
            let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2 - size * 0.06))
            return true
        }
        image.isTemplate = true
        cache[size] = image
        return image
    }

    private static var cache: [CGFloat: NSImage] = [:]
}

extension AgentChatConfigOption {
    /// The agent's model setting, its thinking level and its permission mode.
    static let modelCategory = "model"
    static let thinkingCategory = "thought_level"
    static let modeCategory = "mode"

    /// The model a value names, as the chip shows it: "Claude Opus 5.5 · anthropic" (the
    /// provider from the value's `provider/id`).
    static func modelTitle(_ value: Value) -> String {
        guard let provider = provider(of: value) else { return value.name }
        return "\(value.name) · \(provider)"
    }

    static func provider(of value: Value) -> String? {
        let qualified = value.detail ?? value.value
        guard let slash = qualified.firstIndex(of: "/"), slash != qualified.startIndex else { return nil }
        return String(qualified[..<slash])
    }

    var currentValueEntry: Value? {
        values.first { $0.value == currentValue }
    }
}

// MARK: - Model picker

/// The model picker: a 44 pt column with the agent's mark and the searchable model list with
/// the current model checked, ⌘1–9 jumps and Enter to pick (Soprano Agents' `ModelPickerContent`).
final class ModelPickerContent: ComposerPopoverContent {
    private static let sidebarWidth: CGFloat = 44
    private static let width: CGFloat = 360 + sidebarWidth
    /// Agents list every model of every configured provider; rebuilding that many rows per
    /// keystroke stalls, so the list shows the first matches and a count of the rest.
    static let rowLimit = 80

    private let option: AgentChatConfigOption
    private let agentName: String
    private let onSelect: (String) -> Void
    private let sidebar = PaletteView()
    private let tile = AgentTile()
    private let indicator = PaletteView()
    private let listColumn = PaletteView()
    private let search = ComposerSearchField(placeholder: "Search models...")
    private let list = ComposerListView(maxHeight: 280, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 4))
    private let emptyLabel = NSTextField.label("No models found", size: Typography.bodySize)
    private var shown: [AgentChatConfigOption.Value] = []

    init(option: AgentChatConfigOption, agentName: String, onSelect: @escaping (String) -> Void) {
        self.option = option
        self.agentName = agentName
        self.onSelect = onSelect
        super.init(frame: .zero)
        build()
        reload()
        applyPalette(palette)
    }

    override var initialFocus: NSView? { search.field }

    private func build() {
        tile.toolTip = agentName
        tile.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tile)
        indicator.layer?.cornerRadius = 1.5
        indicator.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(indicator)
        emptyLabel.alignment = .center

        let column = ComposerColumn([search, list, emptyLabel])
        column.setSpacing(4, after: search)
        listColumn.addSubview(column)
        for view in [sidebar, listColumn] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let separator = ComposerDivider(vertical: true)
        listColumn.addSubview(separator)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            listColumn.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            listColumn.topAnchor.constraint(equalTo: topAnchor),
            listColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            listColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            widthAnchor.constraint(equalToConstant: Self.width),
            tile.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            tile.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 4),
            indicator.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            indicator.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 3),
            indicator.heightAnchor.constraint(equalToConstant: 20),
            column.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 1),
            column.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            column.topAnchor.constraint(equalTo: listColumn.topAnchor),
            column.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            separator.topAnchor.constraint(equalTo: listColumn.topAnchor),
            separator.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor),
            emptyLabel.heightAnchor.constraint(equalToConstant: 40),
        ])
        search.onChange = { [weak self] _ in self?.reload() }
    }

    /// Models whose name, provider or id contains every whitespace-separated word of `query`.
    static func matching(_ values: [AgentChatConfigOption.Value], query: String) -> [AgentChatConfigOption.Value] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return values }
        return values.filter { value in
            let haystack = "\(value.name) \(value.detail ?? "") \(value.value)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private func reload() {
        let query = search.text.trimmingCharacters(in: .whitespaces)
        let matches = Self.matching(option.values, query: query)
        let hidden = max(0, matches.count - Self.rowLimit)
        shown = Array(matches.prefix(Self.rowLimit))
        // The current model stays visible in the last slot when it falls past the cut.
        if hidden > 0, !shown.contains(where: { $0.value == option.currentValue }),
           let current = matches.first(where: { $0.value == option.currentValue }) {
            shown[shown.count - 1] = current
        }
        var rows = shown.enumerated().map { index, value in
            ComposerListRow.Model(
                title: value.name,
                trailingNote: AgentChatConfigOption.provider(of: value),
                kbd: index < 9 ? "⌘\(index + 1)" : nil,
                showsCheck: true,
                isChecked: value.value == option.currentValue,
                isCurrent: value.value == option.currentValue
            )
        }
        var actions: [() -> Void] = shown.map { value in { [weak self] in self?.pick(value.value) } }
        if hidden > 0 {
            rows.append(ComposerListRow.Model(title: "\(hidden) more — type to search", isDisabled: true))
            actions.append {}
        }
        let current = shown.firstIndex { $0.value == option.currentValue }
        list.setRows(rows, actions: actions, highlight: query.isEmpty ? (current ?? 0) : 0)
        list.isHidden = shown.isEmpty
        emptyLabel.isHidden = !shown.isEmpty
        requestResize?()
    }

    private func pick(_ value: String) {
        onSelect(value)
        requestClose?()
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            list.choose(digit - 1)
            return true
        }
        switch event.keyCode {
        case 125: list.moveHighlight(by: 1); return true
        case 126: list.moveHighlight(by: -1); return true
        case 36, 76: return list.chooseHighlighted()
        default: return super.handleKey(event)
        }
    }

    override func applyPalette(_ palette: Palette) {
        sidebar.layer?.backgroundColor = palette.muted.composerFaded(0.3).cgColor
        listColumn.layer?.backgroundColor = palette.muted.composerFaded(0.4).cgColor
        indicator.layer?.backgroundColor = palette.primary.cgColor
        emptyLabel.textColor = palette.mutedForeground
    }
}

/// The agent in the model picker's column: its mark in a square, shown selected.
private final class AgentTile: PaletteView {
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        imageView.image = ChatAgentGlyph.image(size: 20)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(0.08).cgColor
        imageView.contentTintColor = palette.foreground
    }
}

// MARK: - Option menu

/// One session setting's choices — the thinking level, the permission mode — as Soprano Agents'
/// traits menu lists its "Reasoning" group: a muted group label over radio rows with their
/// descriptions, the current one checked; ↑/↓ and Enter pick.
final class ConfigOptionMenuContent: ComposerPopoverContent {
    private let option: AgentChatConfigOption
    private let onSelect: (String) -> Void
    private let label: NSTextField
    private let list = ComposerListView(maxHeight: 400, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))

    init(option: AgentChatConfigOption, onSelect: @escaping (String) -> Void) {
        self.option = option
        self.onSelect = onSelect
        label = composerMenuLabel(option.name)
        super.init(frame: .zero)
        let labelBox = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        labelBox.addSubview(label)
        let stack = ComposerColumn([labelBox, list], insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        addSubview(stack)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: labelBox.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: labelBox.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: labelBox.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: labelBox.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 296),
        ])
        let rows = option.values.map { value in
            ComposerListRow.Model(
                title: ConfigOptionMenuContent.title(value.name),
                subtitle: value.detail,
                showsCheck: true,
                isChecked: value.value == option.currentValue,
                isCurrent: value.value == option.currentValue
            )
        }
        let actions: [() -> Void] = option.values.map { value in { [weak self] in self?.pick(value.value) } }
        list.setRows(rows, actions: actions, highlight: option.values.firstIndex { $0.value == option.currentValue })
        applyPalette(palette)
    }

    /// Thinking levels arrive lowercase ("high"): shown capitalized like Soprano Agents' effort labels.
    static func title(_ name: String) -> String {
        guard let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }

    private func pick(_ value: String) {
        onSelect(value)
        requestClose?()
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: list.moveHighlight(by: 1); return true
        case 126: list.moveHighlight(by: -1); return true
        case 36, 76: return list.chooseHighlighted()
        default: return super.handleKey(event)
        }
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
    }
}
