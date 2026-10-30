import AppKit
import SopranoAgentsCore

/// What the "Commit changes" dialog returns.
struct CommitDialogResult: Equatable {
    /// nil = generate one.
    var message: String?
    /// nil = every changed file.
    var filePaths: [String]?
    var featureBranch: Bool
}

/// The "Commit changes" dialog, shown as a child window over the
/// main window with a dimmed backdrop: Branch, Files (Edit toggles checkboxes), "Commit message
/// (optional)", and Cancel / Commit on new branch / Commit.
@MainActor
final class CommitDialog: NSObject, NSTextViewDelegate {
    private let status: GitStatusSummary
    private var excluded: Set<String> = []
    private var isEditingFiles = false
    private var completion: ((CommitDialogResult?) -> Void)?
    private weak var parentWindow: NSWindow?
    private var panel: CommitDialogPanel?

    private let card = CommitDialogCard()
    private let filesHeader = NSTextField.label(size: Typography.bodySize)
    private let editButton = TextButton("Edit", variant: .ghost, size: .xs)
    private let selectAll = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let fileRows = NSStackView()
    private let totals = NSTextField.label(size: Typography.smallSize)
    private let messageView = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 462, height: 72))
    private var checkboxes: [String: NSButton] = [:]
    private var rowStatus: [String: NSTextField] = [:]
    private var rowPaths: [String: NSTextField] = [:]

    /// The open dialog, kept alive while shown.
    private static var current: CommitDialog?

    private init(status: GitStatusSummary) {
        self.status = status
        super.init()
    }

    /// Shows the dialog over `window`; `completion` gets nil on Cancel / Escape.
    static func present(status: GitStatusSummary, in window: NSWindow, completion: @escaping (CommitDialogResult?) -> Void) {
        current?.finish(nil)
        let dialog = CommitDialog(status: status)
        current = dialog
        dialog.completion = completion
        dialog.show(in: window)
    }

    /// The dialog on screen, if any (tests, snapshot).
    static var isPresented: Bool { current != nil }

    private func show(in window: NSWindow) {
        parentWindow = window
        let palette = PaletteCenter.shared.palette
        let panel = CommitDialogPanel(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.finish(nil) }
        panel.appearance = palette.appearance
        let backdrop = CommitDialogBackdrop(frame: NSRect(origin: .zero, size: window.frame.size))
        panel.contentView = backdrop
        build(into: backdrop)
        window.addChildWindow(panel, ordered: .above)
        panel.setFrame(window.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(messageView)
        self.panel = panel
    }

    private func build(into backdrop: NSView) {
        let palette = PaletteCenter.shared.palette
        card.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 512),
        ])

        let title = NSTextField.label("Commit changes", size: 18, weight: .semibold)
        title.textColor = palette.foreground
        let description = NSTextField(wrappingLabelWithString: "Review and confirm your commit. Leave the message blank to auto-generate one.")
        description.font = Typography.ui(Typography.bodySize)
        description.textColor = palette.mutedForeground

        // Branch row
        let branchLabel = NSTextField.label("Branch", size: Typography.bodySize)
        branchLabel.textColor = palette.mutedForeground
        let branchName = NSTextField.label(status.branch ?? "(detached HEAD)", size: Typography.bodySize, weight: .medium)
        branchName.textColor = palette.foreground
        let branchRow = NSStackView(views: [branchLabel, branchName])
        branchRow.spacing = 8
        if status.isDefaultBranch {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let warning = NSTextField.label("Default branch", size: Typography.bodySize)
            warning.textColor = palette.warningForeground
            branchRow.addArrangedSubview(spacer)
            branchRow.addArrangedSubview(warning)
        }

        // Files header
        filesHeader.textColor = palette.mutedForeground
        selectAll.target = self
        selectAll.action = #selector(toggleAll)
        selectAll.allowsMixedState = true
        editButton.onClick = { [weak self] in self?.toggleEditing() }
        let filesSpacer = NSView()
        filesSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let filesTop = NSStackView(views: [selectAll, filesHeader, filesSpacer, editButton])
        filesTop.spacing = 8
        filesTop.alignment = .centerY

        let infoStack = NSStackView(views: [branchRow, filesTop])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        branchRow.translatesAutoresizingMaskIntoConstraints = false
        filesTop.translatesAutoresizingMaskIntoConstraints = false

        if status.files.isEmpty {
            let none = NSTextField.label("none", size: Typography.bodySize, weight: .medium)
            none.textColor = palette.foreground
            infoStack.addArrangedSubview(none)
            editButton.isHidden = true
        } else {
            fileRows.orientation = .vertical
            fileRows.alignment = .leading
            fileRows.spacing = 2
            fileRows.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            for file in status.files {
                fileRows.addArrangedSubview(makeFileRow(file, palette: palette))
            }
            let list = FlippedClipDocument()
            list.translatesAutoresizingMaskIntoConstraints = false
            fileRows.translatesAutoresizingMaskIntoConstraints = false
            list.addSubview(fileRows)
            NSLayoutConstraint.activate([
                fileRows.topAnchor.constraint(equalTo: list.topAnchor),
                fileRows.leadingAnchor.constraint(equalTo: list.leadingAnchor),
                fileRows.trailingAnchor.constraint(equalTo: list.trailingAnchor),
                fileRows.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            ])
            let scroll = NSScrollView()
            scroll.documentView = list
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let listBox = Self.box(
                scroll,
                fill: palette.isDark ? NSColor.white.withAlphaComponent(0.025) : palette.card,
                border: palette.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.05)
            )
            NSLayoutConstraint.activate([
                listBox.heightAnchor.constraint(equalToConstant: 176),
                list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            ])
            infoStack.addArrangedSubview(listBox)
            listBox.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
            let totalsSpacer = NSView()
            totalsSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let totalsRow = NSStackView(views: [totalsSpacer, totals])
            totalsRow.alignment = .centerY
            infoStack.addArrangedSubview(totalsRow)
            totalsRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        }
        branchRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        filesTop.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true

        let info = NSView()
        info.wantsLayer = true
        info.layer?.cornerRadius = Radius.xl
        info.layer?.backgroundColor = (palette.isDark ? NSColor.white.withAlphaComponent(0.035) : palette.background).cgColor
        info.layer?.borderWidth = 1
        info.layer?.borderColor = (palette.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.05)).cgColor
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(infoStack)
        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: info.topAnchor, constant: 12),
            infoStack.leadingAnchor.constraint(equalTo: info.leadingAnchor, constant: 12),
            infoStack.trailingAnchor.constraint(equalTo: info.trailingAnchor, constant: -12),
            infoStack.bottomAnchor.constraint(equalTo: info.bottomAnchor, constant: -12),
        ])

        // Message
        let messageLabel = NSTextField.label("Commit message (optional)", size: Typography.bodySize, weight: .medium)
        messageLabel.textColor = palette.foreground
        messageView.placeholder = "Leave empty to auto-generate"
        messageView.font = Typography.ui(Typography.bodySize)
        messageView.textColor = palette.foreground
        messageView.insertionPointColor = palette.foreground
        messageView.drawsBackground = false
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.textContainerInset = NSSize(width: 6, height: 6)
        messageView.delegate = self
        messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.drawsBackground = false
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        let messageBox = Self.box(messageScroll, fill: palette.isDark ? palette.input.fading(0.32) : palette.popover, border: palette.input)
        messageBox.heightAnchor.constraint(equalToConstant: 72).isActive = true

        // Buttons
        let cancel = TextButton("Cancel", variant: .outline, size: .regular)
        let newBranch = TextButton("Commit on new branch", variant: .outline, size: .regular)
        let commit = TextButton("Commit", variant: .primary, size: .regular)
        cancel.onClick = { [weak self] in self?.finish(nil) }
        newBranch.onClick = { [weak self] in self?.submit(featureBranch: true) }
        commit.onClick = { [weak self] in self?.submit(featureBranch: false) }
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancel, newBranch, commit])
        buttons.spacing = 8

        let content = NSStackView(views: [title, description, info, messageLabel, messageBox, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.setCustomSpacing(16, after: description)
        content.setCustomSpacing(16, after: info)
        content.setCustomSpacing(20, after: messageBox)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
        for view in [description, info, messageBox, buttons] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        updateFiles()
    }

    private func makeFileRow(_ file: ChangedFileStat, palette: Palette) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFile(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(file.path)
        checkbox.state = .on
        checkboxes[file.path] = checkbox
        let path = NSTextField.label(file.path, size: Typography.smallSize)
        path.font = Typography.mono(Typography.smallSize)
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowPaths[file.path] = path
        let counts = NSTextField.label(size: Typography.smallSize)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStatus[file.path] = counts
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [checkbox, path, spacer, counts])
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func updateFiles() {
        let palette = PaletteCenter.shared.palette
        let all = status.files
        let selected = all.filter { !excluded.contains($0.path) }
        selectAll.isHidden = !isEditingFiles || all.isEmpty
        selectAll.state = selected.count == all.count ? .on : selected.isEmpty ? .off : .mixed
        editButton.title = isEditingFiles ? "Done" : "Edit"
        let showsCount = selected.count != all.count && !isEditingFiles
        filesHeader.stringValue = showsCount ? "Files (\(selected.count) of \(all.count))" : "Files"
        let mono = Typography.mono(Typography.smallSize)
        for file in all {
            checkboxes[file.path]?.isHidden = !isEditingFiles
            checkboxes[file.path]?.state = excluded.contains(file.path) ? .off : .on
            let isExcluded = excluded.contains(file.path)
            rowPaths[file.path]?.textColor = isExcluded ? palette.mutedForeground : palette.foreground
            if isExcluded {
                rowStatus[file.path]?.attributedStringValue = NSAttributedString(string: "Excluded", attributes: [
                    .font: mono, .foregroundColor: palette.mutedForeground,
                ])
            } else {
                rowStatus[file.path]?.attributedStringValue = Self.counts(additions: file.additions, deletions: file.deletions, palette: palette)
            }
        }
        totals.attributedStringValue = Self.counts(
            additions: selected.reduce(0) { $0 + $1.additions },
            deletions: selected.reduce(0) { $0 + $1.deletions },
            palette: palette
        )
    }

    /// `scroll` inside a rounded, filled, bordered box (scroll views reset their own layer).
    static func box(_ scroll: NSScrollView, fill: NSColor, border: NSColor) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Radius.lg
        box.layer?.backgroundColor = fill.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = border.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    /// "+N / -N" in the diff colors.
    static func counts(additions: Int, deletions: Int, palette: Palette) -> NSAttributedString {
        let font = Typography.mono(Typography.smallSize)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(compactDiffCount(additions))", attributes: [.font: font, .foregroundColor: palette.success]))
        text.append(NSAttributedString(string: " / ", attributes: [.font: font, .foregroundColor: palette.mutedForeground]))
        text.append(NSAttributedString(string: "-\(compactDiffCount(deletions))", attributes: [.font: font, .foregroundColor: palette.error]))
        return text
    }

    private func toggleEditing() {
        isEditingFiles.toggle()
        updateFiles()
    }

    @objc private func toggleAll() {
        excluded = excluded.isEmpty ? Set(status.files.map(\.path)) : []
        updateFiles()
    }

    @objc private func toggleFile(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if excluded.contains(path) { excluded.remove(path) } else { excluded.insert(path) }
        updateFiles()
    }

    private func submit(featureBranch: Bool) {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = status.files.map(\.path).filter { !excluded.contains($0) }
        finish(CommitDialogResult(
            message: message.isEmpty ? nil : message,
            filePaths: excluded.isEmpty ? nil : selected,
            featureBranch: featureBranch
        ))
    }

    private func finish(_ result: CommitDialogResult?) {
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        let completion = completion
        self.completion = nil
        if Self.current === self { Self.current = nil }
        completion?(result)
    }

    /// ⌘↩ commits from the message field.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            submit(featureBranch: false)
            return true
        }
        return false
    }
}

/// Borderless key-capable panel for the dialog; Escape cancels.
final class CommitDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Dimmed backdrop (`bg-background/60`) behind the dialog card.
final class CommitDialogBackdrop: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.withAlphaComponent(palette.isDark ? 0.64 : 0.6).cgColor
    }

    override func mouseDown(with event: NSEvent) {}
}

/// The dialog surface: popover fill, 16 pt radius, border, dialog shadow.
final class CommitDialogCard: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.xxl
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 32
        layer?.shadowOffset = CGSize(width: 0, height: -24)
        layer?.masksToBounds = false
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.popover.cgColor
        layer?.borderColor = palette.border.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.9 : 0.35).cgColor
    }
}

/// Flipped document view so short lists start at the top.
final class FlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A text view that draws a placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Typography.ui(),
            .foregroundColor: PaletteCenter.shared.palette.placeholder,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: attributes).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
