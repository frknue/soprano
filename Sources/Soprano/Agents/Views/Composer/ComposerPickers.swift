import AppKit
import SopranoAgentsCore

// MARK: - Model picker

/// The model picker: a 44 pt provider column and a searchable model
/// list with the current model checked, the default badged, ⌘1–9 jumps and Enter to pick.
final class ModelPickerContent: ComposerPopoverContent {
    private let selection: ModelSelection
    private let statuses: [ProviderKind: ProviderStatus]
    /// Threads keep their provider; drafts may switch.
    private let lockedProvider: ProviderKind?
    private let onSelect: (ModelSelection) -> Void

    private var shownProvider: ProviderKind
    private let sidebar = PaletteView()
    private var tiles: [ProviderKind: ProviderTile] = [:]
    private let indicator = PaletteView()
    private var indicatorY: NSLayoutConstraint?
    private let listColumn = PaletteView()
    private let search = ComposerSearchField(placeholder: "Search models...")
    private let list = ComposerListView(maxHeight: 280, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 4))
    private let emptyLabel = NSTextField.label("No models found", size: Typography.bodySize)
    private let notices = ComposerWrappingLabel.make(size: Typography.smallSize)
    private let noticesBox = PaletteView()
    private var shownModels: [ProviderModel] = []

    init(selection: ModelSelection, statuses: [ProviderKind: ProviderStatus], lockedProvider: ProviderKind?, onSelect: @escaping (ModelSelection) -> Void) {
        self.selection = selection
        self.statuses = statuses
        self.lockedProvider = lockedProvider
        self.onSelect = onSelect
        shownProvider = selection.provider
        super.init(frame: .zero)
        build()
        reload()
        applyPalette(palette)
    }

    override var initialFocus: NSView? { search.field }

    private func build() {
        let tileStack = NSStackView()
        tileStack.orientation = .vertical
        tileStack.spacing = 4
        tileStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for kind in ProviderKind.allCases {
            let tile = ProviderTile(kind: kind)
            let status = statuses[kind]
            if let lockedProvider, lockedProvider != kind {
                tile.isEnabled = false
                tile.toolTip = "\(kind.displayName) is unavailable in this thread. Start a new thread to switch providers."
            } else if let reason = Self.unavailableReason(status) {
                tile.isEnabled = false
                tile.toolTip = reason
            } else {
                tile.toolTip = kind.displayName
            }
            tile.setAccessibilityLabel(tile.toolTip)
            tile.onClick = { [weak self] in self?.showProvider(kind) }
            tiles[kind] = tile
            tileStack.addArrangedSubview(tile)
        }
        tileStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tileStack)
        indicator.layer?.cornerRadius = 1.5
        indicator.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(indicator)

        notices.translatesAutoresizingMaskIntoConstraints = false
        noticesBox.addSubview(notices)
        let noticeLine = ComposerDivider()
        noticesBox.addSubview(noticeLine)
        emptyLabel.alignment = .center

        let column = ComposerColumn([search, list, emptyLabel, noticesBox])
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
            sidebar.widthAnchor.constraint(equalToConstant: 44),
            listColumn.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            listColumn.topAnchor.constraint(equalTo: topAnchor),
            listColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            listColumn.heightAnchor.constraint(greaterThanOrEqualTo: tileStack.heightAnchor),
            widthAnchor.constraint(equalToConstant: 360),
            tileStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tileStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tileStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            indicator.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
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
            noticeLine.leadingAnchor.constraint(equalTo: noticesBox.leadingAnchor),
            noticeLine.trailingAnchor.constraint(equalTo: noticesBox.trailingAnchor),
            noticeLine.topAnchor.constraint(equalTo: noticesBox.topAnchor),
            notices.leadingAnchor.constraint(equalTo: noticesBox.leadingAnchor, constant: 12),
            notices.trailingAnchor.constraint(equalTo: noticesBox.trailingAnchor, constant: -12),
            notices.topAnchor.constraint(equalTo: noticeLine.bottomAnchor, constant: 8),
            notices.bottomAnchor.constraint(equalTo: noticesBox.bottomAnchor, constant: -4),
        ])
        notices.preferredMaxLayoutWidth = 360 - 44 - 24
        search.onChange = { [weak self] _ in self?.reload() }

        let unavailable = ProviderKind.allCases.compactMap { Self.unavailableReason(statuses[$0]) }
        notices.stringValue = unavailable.joined(separator: "\n")
        noticesBox.isHidden = unavailable.isEmpty
    }

    /// "Claude Code: Not installed. <message>" for providers the picker cannot use.
    static func unavailableReason(_ status: ProviderStatus?) -> String? {
        guard let status else { return nil }
        let kind: String
        switch status.health {
        case .ready, .unknown: return nil
        case .notInstalled: kind = "Not installed"
        case .unauthenticated: kind = "Not signed in"
        case .error: kind = "Unavailable"
        }
        if let message = status.message, !message.isEmpty {
            return "\(status.kind.displayName): \(kind). \(message)"
        }
        return "\(status.kind.displayName): \(kind)."
    }

    private func showProvider(_ kind: ProviderKind) {
        guard kind != shownProvider else { return }
        shownProvider = kind
        reload()
        requestResize?()
    }

    /// omp lists every model of every configured provider (700+); rebuilding that many rows per
    /// keystroke stalls, so the list shows the first matches and a count of the rest.
    nonisolated static let rowLimit = 80

    /// Models whose name or slug contains every whitespace-separated word of `query`.
    nonisolated static func matching(_ models: [ProviderModel], query: String) -> [ProviderModel] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return models }
        return models.filter { model in
            let haystack = "\(model.name) \(model.slug)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// The first `limit` matches, with the current model kept visible in the last slot when it
    /// falls past the cut, and how many matches stay hidden.
    nonisolated static func window(_ matches: [ProviderModel], limit: Int, isCurrent: (ProviderModel) -> Bool) -> (shown: [ProviderModel], hidden: Int) {
        let hidden = max(0, matches.count - limit)
        var shown = Array(matches.prefix(limit))
        if hidden > 0, !shown.contains(where: isCurrent), let current = matches.first(where: isCurrent) {
            shown[shown.count - 1] = current
        }
        return (shown, hidden)
    }

    private func reload() {
        let query = search.text.trimmingCharacters(in: .whitespaces)
        let models = ModelChoice.models(for: shownProvider, status: statuses[shownProvider])
        let isCurrent = { [shownProvider, selection] (model: ProviderModel) in
            shownProvider == selection.provider && model.slug == selection.model
        }
        let (shown, hidden) = Self.window(Self.matching(models, query: query), limit: Self.rowLimit, isCurrent: isCurrent)
        shownModels = shown
        var rows = shownModels.enumerated().map { index, model in
            ComposerListRow.Model(
                title: model.name,
                badge: model.isDefault ? "Default" : nil,
                kbd: index < 9 ? "⌘\(index + 1)" : nil,
                showsCheck: true,
                isChecked: isCurrent(model),
                isCurrent: isCurrent(model)
            )
        }
        var actions: [() -> Void] = shownModels.map { model in { [weak self] in self?.pick(model) } }
        if hidden > 0 {
            rows.append(ComposerListRow.Model(title: "\(hidden) more — type to search", isDisabled: true))
            actions.append {}
        }
        let current = shownModels.firstIndex(where: isCurrent)
        list.setRows(rows, actions: actions, highlight: query.isEmpty ? (current ?? 0) : 0)
        list.isHidden = shownModels.isEmpty
        emptyLabel.isHidden = !shownModels.isEmpty
        for (kind, tile) in tiles {
            tile.isSelected = kind == shownProvider
        }
        placeIndicator()
        requestResize?()
    }

    private func pick(_ model: ProviderModel) {
        onSelect(ModelChoice.selecting(model, of: shownProvider, from: selection))
        requestClose?()
    }

    /// Pins the selected-provider pill (`right-1`, 3×20, primary) to the shown provider's tile.
    private func placeIndicator() {
        indicatorY?.isActive = false
        guard let tile = tiles[shownProvider] else { return }
        let constraint = indicator.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        constraint.isActive = true
        indicatorY = constraint
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
        notices.textColor = palette.mutedForeground
    }
}

/// A provider in the model picker's sidebar: its mark in a square button.
private final class ProviderTile: InteractiveView {
    private let imageView = NSImageView()
    let kind: ProviderKind

    var isSelected = false {
        didSet { applyPalette(palette) }
    }

    init(kind: ProviderKind) {
        self.kind = kind
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        imageView.image = ProviderGlyph.image(for: kind, size: 20)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered && isEnabled ? palette.foreground.withAlphaComponent(0.1) : .clear).cgColor
        imageView.contentTintColor = palette.foreground
        alphaValue = isEnabled ? 1 : 0.5
    }
}

// MARK: - Traits menu

/// The traits menu: "Reasoning" radio list, a Fast Mode switch, and the Permissions
/// section (4-segment icon radio with the mode's name and description). The permissions chip
/// opens the Permissions section alone.
final class TraitsMenuContent: ComposerPopoverContent {
    private var selection: ModelSelection
    private let model: ProviderModel?
    private var runtimeMode: RuntimeMode
    private let onSelection: (ModelSelection) -> Void
    private let onRuntimeMode: (RuntimeMode) -> Void

    private let stack = ComposerColumn(insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
    private var labels: [NSTextField] = []
    private var effortList: ComposerListView?
    private var effortChoices: [ModelOptionChoice] = []
    private var fastSwitch: ComposerSwitch?
    private var fastRow: ComposerHoverRow?
    private var fastLabel: NSTextField?
    private let segments = PaletteView()
    private var segmentButtons: [RuntimeMode: PermissionSegment] = [:]
    private let modeName = NSTextField.label("", size: Typography.bodySize)
    private let modeDescription = NSTextField(wrappingLabelWithString: "")

    init(
        selection: ModelSelection,
        model: ProviderModel?,
        runtimeMode: RuntimeMode,
        includesModelOptions: Bool,
        onSelection: @escaping (ModelSelection) -> Void,
        onRuntimeMode: @escaping (RuntimeMode) -> Void
    ) {
        self.selection = selection
        self.model = model
        self.runtimeMode = runtimeMode
        self.onSelection = onSelection
        self.onRuntimeMode = onRuntimeMode
        super.init(frame: .zero)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 296),
        ])
        if includesModelOptions {
            buildModelOptions()
        }
        buildPermissions()
        applyPalette(palette)
    }

    private func groupLabel(_ text: String) -> NSView {
        let label = composerMenuLabel(text)
        labels.append(label)
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        return box
    }

    private func divider() -> NSView {
        let box = NSView()
        let line = ComposerDivider()
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: -4),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: 4),
            line.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 9),
        ])
        return box
    }

    private func buildModelOptions() {
        if let effort = model?.option(ModelOptionID.effort), effort.kind == .select {
            stack.add(groupLabel(effort.label))
            let list = ComposerListView(maxHeight: 400, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
            effortChoices = effort.choices
            effortList = list
            stack.add(list)
            reloadEffort()
        }
        if model?.option(ModelOptionID.fastMode) != nil {
            if effortList != nil { stack.add(divider()) }
            let row = ComposerHoverRow()
            let label = NSTextField.label("Fast Mode", size: Typography.bodySize)
            let toggle = ComposerSwitch()
            toggle.isOn = ModelChoice.effectiveFastMode(selection, model: model)
            for view in [label, toggle] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(view)
            }
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 28),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            row.setAccessibilityRole(.checkBox)
            row.setAccessibilityLabel("Fast Mode")
            row.onClick = { [weak self] in self?.toggleFast() }
            fastRow = row
            fastSwitch = toggle
            fastLabel = label
            stack.add(row)
        }
        if effortList != nil || fastRow != nil {
            stack.add(divider())
        }
    }

    private func reloadEffort() {
        guard let effortList, let option = model?.option(ModelOptionID.effort) else { return }
        let current = ModelChoice.effectiveEffort(selection, model: model)
        let rows = effortChoices.map { choice in
            ComposerListRow.Model(
                title: ProviderCatalog.effortLabel(choice.id),
                subtitle: choice.description,
                badge: choice.id == option.defaultValue ? "Default" : nil,
                isChecked: choice.id == current,
                isCurrent: choice.id == current
            )
        }
        let actions: [() -> Void] = effortChoices.map { choice in { [weak self] in self?.pickEffort(choice.id) } }
        effortList.setRows(rows, actions: actions, highlight: nil)
    }

    private func pickEffort(_ id: String) {
        var next = selection
        next.effort = id
        selection = next
        onSelection(next)
        requestClose?()
    }

    private func toggleFast() {
        guard let fastSwitch else { return }
        var next = selection
        next.options[ModelOptionID.fastMode] = fastSwitch.isOn ? "false" : "true"
        selection = next
        fastSwitch.isOn.toggle()
        onSelection(next)
    }

    private func buildPermissions() {
        let section = NSView()
        let title = composerMenuLabel("Permissions")
        labels.append(title)
        segments.layer?.cornerRadius = Radius.lg
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 2
        for mode in RuntimeMode.allCases {
            let button = PermissionSegment(mode: mode)
            button.onClick = { [weak self] in self?.pickMode(mode) }
            button.onHoverChange = { [weak self] hovered in self?.showMode(hovered ? mode : nil) }
            segmentButtons[mode] = button
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        segments.addSubview(row)
        modeDescription.font = Typography.ui(Typography.smallSize)
        modeDescription.maximumNumberOfLines = 2
        modeDescription.preferredMaxLayoutWidth = 296 - 8 - 24
        for view in [title, segments, modeName, modeDescription] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: section.topAnchor, constant: 6),
            segments.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            segments.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -8),
            segments.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: segments.leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: segments.trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: segments.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: segments.bottomAnchor, constant: -2),
            modeName.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            modeName.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor, constant: -8),
            modeName.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 6),
            modeDescription.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
            modeDescription.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -8),
            modeDescription.topAnchor.constraint(equalTo: modeName.bottomAnchor, constant: 2),
            modeDescription.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            modeDescription.bottomAnchor.constraint(equalTo: section.bottomAnchor, constant: -6),
        ])
        stack.add(section)
        updateSegments()
        showMode(nil)
    }

    private func pickMode(_ mode: RuntimeMode) {
        if mode != runtimeMode {
            runtimeMode = mode
            onRuntimeMode(mode)
        }
        requestClose?()
    }

    private func updateSegments() {
        for (mode, button) in segmentButtons {
            button.isChecked = mode == runtimeMode
        }
    }

    /// Hover previews a mode's name and description before a pick.
    private func showMode(_ preview: RuntimeMode?) {
        let shown = preview ?? runtimeMode
        modeName.stringValue = shown.title
        modeDescription.stringValue = shown.summary
        modeName.textColor = shown == runtimeMode ? palette.foreground : palette.mutedForeground
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: effortList?.moveHighlight(by: 1); return effortList != nil
        case 126: effortList?.moveHighlight(by: -1); return effortList != nil
        case 36, 76: return effortList?.chooseHighlighted() ?? false
        case 123, 124:
            let modes = RuntimeMode.allCases
            guard let index = modes.firstIndex(of: runtimeMode) else { return false }
            let next = index + (event.keyCode == 124 ? 1 : -1)
            guard modes.indices.contains(next) else { return true }
            runtimeMode = modes[next]
            onRuntimeMode(runtimeMode)
            updateSegments()
            showMode(nil)
            return true
        default: return super.handleKey(event)
        }
    }

    override func applyPalette(_ palette: Palette) {
        for label in labels { label.textColor = palette.mutedForeground }
        segments.layer?.backgroundColor = palette.input.composerFaded(0.4).cgColor
        modeName.textColor = palette.foreground
        modeDescription.textColor = palette.mutedForeground
        fastLabel?.textColor = palette.foreground
    }
}

/// One segment of the Permissions radio: the mode's icon, checked = `input/72` fill.
private final class PermissionSegment: InteractiveView {
    private let imageView = NSImageView()
    let mode: RuntimeMode
    var onHoverChange: ((Bool) -> Void)?

    var isChecked = false {
        didSet { applyPalette(palette) }
    }

    init(mode: RuntimeMode) {
        self.mode = mode
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.md
        imageView.image = NSImage.symbol(mode.symbolName, size: 12, weight: .medium)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = mode.title
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(mode.title)
        applyPalette(palette)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func applyPalette(_ palette: Palette) {
        let fill: NSColor = isChecked ? palette.input.composerFaded(0.72) : (isHovered ? palette.accent : .clear)
        layer?.backgroundColor = fill.cgColor
        imageView.contentTintColor = isChecked || isHovered ? palette.foreground : palette.mutedForeground
    }
}

// MARK: - Branch picker

/// The branch picker: "Search refs...", refs with current/worktree/remote/default badges,
/// "No refs found.", and `Create new ref "<name>"` (shown disabled: drafts never create refs).
final class BranchPickerContent: ComposerPopoverContent {
    private var branches: [GitBranchRef]?
    private let selected: String?
    private let projectPath: String?
    private let onSelect: (GitBranchRef) -> Void
    private let search = ComposerSearchField(placeholder: "Search refs...")
    private let list = ComposerListView(maxHeight: 224, insets: NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4))
    private let status = NSTextField.label("Loading refs...", size: Typography.bodySize)

    init(branches: [GitBranchRef]?, selected: String?, projectPath: String?, onSelect: @escaping (GitBranchRef) -> Void) {
        self.branches = branches
        self.selected = selected
        self.projectPath = projectPath
        self.onSelect = onSelect
        super.init(frame: .zero)
        status.alignment = .center
        let stack = ComposerColumn([search, list, status])
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 320),
            status.heightAnchor.constraint(equalToConstant: 40),
        ])
        search.onChange = { [weak self] _ in self?.reload() }
        reload()
        applyPalette(palette)
    }

    override var initialFocus: NSView? { search.field }

    func setBranches(_ branches: [GitBranchRef]) {
        self.branches = branches
        reload()
    }

    private func reload() {
        let query = search.text.trimmingCharacters(in: .whitespaces)
        guard let branches else {
            list.setRows([], actions: [], highlight: nil)
            list.isHidden = true
            status.stringValue = "Loading refs..."
            status.isHidden = false
            requestResize?()
            return
        }
        let matches = query.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
        var rows = matches.map { ref in
            ComposerListRow.Model(
                title: ref.name,
                trailingNote: BranchLabel.badge(for: ref, projectPath: projectPath),
                isCurrent: ref.name == selected
            )
        }
        var actions: [() -> Void] = matches.map { ref in { [weak self] in self?.pick(ref) } }
        if !query.isEmpty, !branches.contains(where: { $0.name == query }) {
            rows.append(ComposerListRow.Model(
                title: "Create new ref \"\(query)\"",
                isDisabled: true,
                toolTip: "New threads start from an existing ref."
            ))
            actions.append({})
        }
        let current = matches.firstIndex { $0.name == selected }
        list.setRows(rows, actions: actions, highlight: query.isEmpty ? (current ?? 0) : 0)
        list.isHidden = rows.isEmpty
        status.stringValue = "No refs found."
        status.isHidden = !rows.isEmpty
        requestResize?()
    }

    private func pick(_ ref: GitBranchRef) {
        onSelect(ref)
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
        status.textColor = palette.mutedForeground
    }
}

// MARK: - Workspace menu

/// "Workspace": Current checkout / New worktree.
final class WorkspaceMenuContent: ComposerPopoverContent {
    private let list = ComposerListView(maxHeight: 200, insets: NSEdgeInsets(top: 0, left: 4, bottom: 4, right: 4))
    private let title = composerMenuLabel("Workspace")

    init(usesWorktree: Bool, onSelect: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        let header = NSView()
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        let stack = ComposerColumn([header, list])
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 200),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
        ])
        let rows = [
            ComposerListRow.Model(title: "Current checkout", image: NSImage.symbol(Icon.folder, size: 13), showsCheck: true, isChecked: !usesWorktree, isCurrent: !usesWorktree),
            ComposerListRow.Model(title: "New worktree", image: NSImage.symbol(Icon.folderGit, size: 13), showsCheck: true, isChecked: usesWorktree, isCurrent: usesWorktree),
        ]
        let actions: [() -> Void] = [false, true].map { value in
            { [weak self] in
                onSelect(value)
                self?.requestClose?()
            }
        }
        list.setRows(rows, actions: actions, highlight: usesWorktree ? 1 : 0)
        applyPalette(palette)
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
        title.textColor = palette.mutedForeground
    }
}

// MARK: - Project picker

/// The draft hero's project combobox: "Choose a project", "Search projects...", the projects,
/// "Add a project" and "No project".
final class ProjectPickerContent: ComposerPopoverContent {
    enum Choice {
        case project(String)
        case addProject
        case noProject
    }

    private let projects: [Project]
    private let selectedID: String?
    private let onSelect: (Choice) -> Void
    private let title = composerMenuLabel("Choose a project")
    private let search = ComposerSearchField(placeholder: "Search projects...")
    private let list = ComposerListView(maxHeight: 260, insets: NSEdgeInsets(top: 6, left: 4, bottom: 4, right: 4))
    private let empty = NSTextField.label("No matching projects.", size: Typography.bodySize)

    init(projects: [Project], selectedID: String?, onSelect: @escaping (Choice) -> Void) {
        self.projects = projects
        self.selectedID = selectedID
        self.onSelect = onSelect
        super.init(frame: .zero)
        let header = NSView()
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        empty.alignment = .center
        let stack = ComposerColumn([header, search, list, empty])
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 288),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            empty.heightAnchor.constraint(equalToConstant: 40),
        ])
        search.onChange = { [weak self] _ in self?.reload() }
        reload()
        applyPalette(palette)
    }

    override var initialFocus: NSView? { search.field }

    private func reload() {
        let query = search.text.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? projects : projects.filter { $0.title.localizedCaseInsensitiveContains(query) }
        var rows = matches.map { project in
            ComposerListRow.Model(
                title: project.title,
                image: NSImage.symbol(Icon.folder, size: 13),
                showsCheck: true,
                isChecked: project.id == selectedID,
                isCurrent: project.id == selectedID,
                toolTip: project.path
            )
        }
        var actions: [() -> Void] = matches.map { project in { [weak self] in self?.pick(.project(project.id)) } }
        if query.isEmpty {
            rows.append(ComposerListRow.Model(title: "Add a project", image: NSImage.symbol(Icon.folderPlus, size: 13), showsCheck: true))
            actions.append { [weak self] in self?.pick(.addProject) }
            rows.append(ComposerListRow.Model(title: "No project", image: NSImage.symbol(Icon.messageCircle, size: 13), showsCheck: true, isChecked: selectedID == nil, isCurrent: selectedID == nil))
            actions.append { [weak self] in self?.pick(.noProject) }
        }
        let current = matches.firstIndex { $0.id == selectedID }
        list.setRows(rows, actions: actions, highlight: query.isEmpty ? (current ?? 0) : 0)
        list.isHidden = rows.isEmpty
        empty.isHidden = !rows.isEmpty
        requestResize?()
    }

    private func pick(_ choice: Choice) {
        requestClose?()
        onSelect(choice)
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
        title.textColor = palette.mutedForeground
        empty.textColor = palette.mutedForeground
    }
}
