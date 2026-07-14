# Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Soprano's settings UI as a cohesive themed design (grouped sections, custom toggle, key badges, page headers) per `docs/superpowers/specs/2026-07-14-settings-redesign-design.md`.

**Architecture:** Add a small component kit (`SettingsComponents.swift`) with section/row/toggle/badge views plus styling helpers, then rewrite the four tab builders in `SettingsWindowController.swift` to compose those components. All state, callbacks, and persistence in `SettingsViewController` stay untouched.

**Tech Stack:** Swift 6 / AppKit, no third-party deps, no test framework (verification = build + screenshot via the background driver harness).

## Global Constraints

- Build with Homebrew Swift: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build` — system CLT Swift has broken SPM.
- No test framework exists; every task's "test" is a clean build plus a screenshot check with the background harness (see Verification Harness below).
- Code conventions (CLAUDE.md): `final class`; `@available(*, unavailable) required init?(coder:)` on all NSView subclasses; `translatesAutoresizingMaskIntoConstraints = false` + `NSLayoutConstraint.activate`; 4-space indent; trailing commas in multi-line structures; multi-class-per-file for self-contained features.
- Theme tokens come from `AppTheme.colors` (`Theme.swift`): `bgBase, bgPanel, bgRaised, bgOverlay, textPrimary, textMuted, accent, accentStrong, borderSubtle, borderStrong, success, danger, blue, cyan, yellow, gray`.
- Do NOT change: `SettingsViewController` callbacks (`onSettingsChanged`, `onKeybindingConfigChanged`), the `@objc` action methods' behavior, persistence calls (`settings.save()`, `DefaultKeybindings.save`), or the tab enum.
- Theme switching restyles by full tab rebuild (`apply(theme:)` → `rebuildCurrentTab()`), so components take the theme in `init` — they do not need their own `apply(theme:)`.

## Verification Harness

The session scratchpad (`/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/9e9fcddb-8db6-44ed-84e6-511936c98f28/scratchpad`) contains `driver` (postToPid event injector, source `driver.swift`) and `allwin` (window lister, source `allwin.swift`). If the binaries are missing, recompile:

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/9e9fcddb-8db6-44ed-84e6-511936c98f28/scratchpad
/opt/homebrew/opt/swift/bin/swiftc -sdk "$(xcrun --show-sdk-path)" -O -o "$SCRATCH/driver" "$SCRATCH/driver.swift"
/opt/homebrew/opt/swift/bin/swiftc -sdk "$(xcrun --show-sdk-path)" -O -o "$SCRATCH/allwin" "$SCRATCH/allwin.swift"
```

Standard verification cycle (background; restores the user's focus after the one launch blip):

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/9e9fcddb-8db6-44ed-84e6-511936c98f28/scratchpad
cd /Users/furkanulker/git/private/soprano
PREV=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
pkill -x Soprano; sleep 1
.build/debug/Soprano > /dev/null 2>&1 &
sleep 3
osascript -e "tell application \"$PREV\" to activate" || true
PID=$(pgrep -x Soprano | head -1)
WID=$("$SCRATCH/allwin" "$PID" | grep "name=Soprano" | sed -E 's/id=([0-9]+).*/\1/')
"$SCRATCH/driver" key "$PID" 43 cmd        # Cmd+, opens settings
sleep 1.5
# switch tabs without stealing focus:
osascript -e 'tell application "System Events" to tell process "Soprano" to click button "<TAB NAME>" of window 1'
sleep 1
screencapture -x -o -l "$WID" "$SCRATCH/verify-<tab>.png"
```

Read the PNG and compare against the task's expected-appearance checklist. Kill the app afterwards: `pkill -x Soprano`.

---

### Task 1: Settings component kit

**Files:**
- Create: `Sources/Soprano/Views/SettingsComponents.swift`

**Interfaces:**
- Consumes: `AppTheme` (`Theme.swift`).
- Produces (used by Tasks 2–6):
  - `final class SettingsSectionView: NSView` — `init(title: String?, theme: AppTheme)`, `func addRow(_ row: NSView)`
  - `final class SettingsRowView: NSView` — `init(title: String, subtitle: String? = nil, control: NSView? = nil, theme: AppTheme)`
  - `final class ToggleSwitchView: NSView` — `init(isOn: Bool, theme: AppTheme)`, `private(set) var isOn: Bool`, `var onToggle: ((Bool) -> Void)?`, `func setOn(_ on: Bool, animated: Bool)`
  - `final class KeyBadgeView: NSView` — `init(keys: String, theme: AppTheme)`
  - `enum SettingsControls` — `static func pageHeader(title: String, subtitle: String, theme: AppTheme) -> NSView`, `static func themedButton(title: String, target: AnyObject?, action: Selector?, theme: AppTheme) -> NSButton`, `static func themedField(value: String, theme: AppTheme, width: CGFloat? = nil) -> NSTextField`, `static func monoChip(_ text: String, theme: AppTheme) -> NSTextField`

- [ ] **Step 1: Write the file**

```swift
import AppKit

/// Grouped settings section: optional uppercase monospace label above a
/// rounded bgPanel group whose rows are separated by hairline dividers.
final class SettingsSectionView: NSView {
    private let rowsStack = NSStackView()
    private let theme: AppTheme

    init(title: String?, theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        if let title, !title.isEmpty {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            label.textColor = theme.colors.textMuted
            outer.addArrangedSubview(label)
        }

        let group = NSView()
        group.wantsLayer = true
        group.layer?.cornerRadius = 8
        group.layer?.borderWidth = 1
        group.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        group.layer?.borderColor = theme.colors.borderSubtle.cgColor
        group.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(rowsStack)

        outer.addArrangedSubview(group)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),

            group.widthAnchor.constraint(equalTo: outer.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: group.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func addRow(_ row: NSView) {
        if !rowsStack.arrangedSubviews.isEmpty {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(divider)
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
            ])
        }
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }
}

/// Standard settings row: 13pt medium title (+ optional 11pt muted subtitle)
/// on the left, a right-aligned control on the right. Min height 44pt.
final class SettingsRowView: NSView {
    init(title: String, subtitle: String? = nil, control: NSView? = nil, theme: AppTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(titleLabel)

        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = theme.colors.textMuted
            subtitleLabel.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(subtitleLabel)
        }

        addSubview(labels)

        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ]

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            ]
        } else {
            constraints.append(
                labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
            )
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Custom themed toggle switch (36×20). Accent track when on, animated knob.
final class ToggleSwitchView: NSView {
    private(set) var isOn: Bool
    var onToggle: ((Bool) -> Void)?

    private let knob = NSView()
    private let theme: AppTheme
    private var knobLeading: NSLayoutConstraint!

    init(isOn: Bool, theme: AppTheme) {
        self.isOn = isOn
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10

        knob.wantsLayer = true
        knob.layer?.cornerRadius = 8
        knob.layer?.backgroundColor = theme.colors.textPrimary.cgColor
        knob.translatesAutoresizingMaskIntoConstraints = false
        addSubview(knob)

        knobLeading = knob.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: isOn ? 18 : 2
        )
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 20),
            knob.widthAnchor.constraint(equalToConstant: 16),
            knob.heightAnchor.constraint(equalToConstant: 16),
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knobLeading,
        ])
        refreshTrack()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        setOn(!isOn, animated: true)
        onToggle?(isOn)
    }

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        knobLeading.constant = on ? 18 : 2
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                self.refreshTrack()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            refreshTrack()
        }
    }

    private func refreshTrack() {
        layer?.backgroundColor = (isOn ? theme.colors.accent : theme.colors.bgOverlay).cgColor
    }
}

/// Monospace key chip with a correct intrinsic size (never stretches).
final class KeyBadgeView: NSView {
    init(keys: String, theme: AppTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = theme.colors.bgOverlay.cgColor

        let label = NSTextField(labelWithString: keys)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = theme.colors.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Factory helpers for themed leaf controls.
enum SettingsControls {
    /// Page header: 20pt semibold title over a single-line muted subtitle.
    static func pageHeader(title: String, subtitle: String, theme: AppTheme) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = theme.colors.textMuted
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    /// Flat themed push button: bgRaised fill, subtle border, no stock bezel.
    static func themedButton(
        title: String,
        target: AnyObject?,
        action: Selector?,
        theme: AppTheme
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        button.layer?.borderColor = theme.colors.borderSubtle.cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: theme.colors.textPrimary,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = button.intrinsicContentSize.width + 20
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 26),
            button.widthAnchor.constraint(equalToConstant: width),
        ])
        return button
    }

    /// Themed text field; optional fixed width for compact numeric fields.
    static func themedField(value: String, theme: AppTheme, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(string: value)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1
        field.layer?.borderColor = theme.colors.borderSubtle.cgColor
        field.backgroundColor = theme.colors.bgRaised
        field.textColor = theme.colors.textPrimary
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        if let width {
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return field
    }

    /// Small muted monospace chip (e.g. PREFIX / DIRECT mode markers).
    static func monoChip(_ text: String, theme: AppTheme) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = theme.colors.textMuted
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }
}
```

- [ ] **Step 2: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!` (components compile; nothing uses them yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/Soprano/Views/SettingsComponents.swift
git commit -m "feat(settings): add themed settings component kit"
```

---

### Task 2: Content column + sidebar restyle

**Files:**
- Modify: `Sources/Soprano/Views/SettingsWindowController.swift` (`loadView` contentStack setup ~line 221, `addContentSubview` ~line 418, `styleTabButton` ~line 304)

**Interfaces:**
- Consumes: nothing new.
- Produces: `addContentSubview(_ view: NSView)` (drops the `widthInset` parameter; all callers updated in Tasks 3–6; until then keep a deprecated overload — see Step 1).

- [ ] **Step 1: Update content stack, width capping, and sidebar styling**

In `loadView()`, change the contentStack configuration to:

```swift
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
```

Replace `addContentSubview` with a version that caps section width at 560pt (keep the old signature working until all tabs are migrated):

```swift
    private func addContentSubview(_ view: NSView, widthInset: CGFloat? = nil) {
        contentStack.addArrangedSubview(view)
        if let widthInset {
            // Legacy path, removed once all tabs use the capped layout.
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: widthInset).isActive = true
            return
        }
        let fill = view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48)
        fill.priority = .defaultHigh
        let cap = view.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        NSLayoutConstraint.activate([fill, cap])
    }
```

Replace `styleTabButton` body (subtle raised pill instead of accent fill):

```swift
    private func styleTabButton(_ button: NSButton, tab: SettingsTab, active: Bool) {
        let theme = currentTheme
        button.layer?.backgroundColor = active ? theme.colors.bgRaised.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = active ? 1 : 0
        button.layer?.borderColor = theme.colors.borderSubtle.cgColor
        button.contentTintColor = active ? theme.colors.accent : theme.colors.textMuted
        button.attributedTitle = NSAttributedString(
            string: tab.title,
            attributes: [
                .foregroundColor: active ? theme.colors.textPrimary : theme.colors.textMuted,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }
```

- [ ] **Step 2: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 3: Verify via harness**

Run the Verification Harness cycle, capture the General tab (no tab click needed; it's the default). Check in the screenshot: selected "General" tab shows a subtle raised pill with accent icon (no brown fill); old card layout still present (tabs not migrated yet — that's expected).

- [ ] **Step 4: Commit**

```bash
git add Sources/Soprano/Views/SettingsWindowController.swift
git commit -m "feat(settings): cap content width, restyle sidebar tabs"
```

---

### Task 3: General tab rebuild

**Files:**
- Modify: `Sources/Soprano/Views/SettingsWindowController.swift` (`buildGeneralTab` ~line 465, `rebuildProjectDirectoriesList` ~line 564, property `restoreSessionButton` ~line 158)

**Interfaces:**
- Consumes: all Task 1 components; existing actions `themeChanged(_:)`, `browseProjectDirectory`, `addProjectDirectory`, `removeProjectDirectory(_:)`, `prefixKeyCommitted(_:)`, `prefixTimeoutCommitted(_:)`, `resizeStepCommitted(_:)`; existing action `restoreSessionChanged(_:)` is replaced by a toggle closure.
- Produces: property rename `restoreSessionButton: NSButton?` → `restoreSessionToggle: ToggleSwitchView?`.

- [ ] **Step 1: Replace property and delete the checkbox action**

Replace `private var restoreSessionButton: NSButton?` with:

```swift
    private var restoreSessionToggle: ToggleSwitchView?
```

Delete the `@objc private func restoreSessionChanged(_ sender: NSButton)` method (its logic moves into the toggle closure below).

- [ ] **Step 2: Rewrite `buildGeneralTab`**

```swift
    private func buildGeneralTab() {
        addContentSubview(SettingsControls.pageHeader(
            title: "General",
            subtitle: "Theme, persistence, project roots, and keybinding behavior.",
            theme: currentTheme
        ))

        let appearance = SettingsSectionView(title: "Appearance", theme: currentTheme)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(themeChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.removeAllItems()
        popup.addItems(withTitles: AppTheme.allThemes.map(\.name))
        if let selectedIndex = AppTheme.allThemes.firstIndex(where: { $0.id == settings.themeId }) {
            popup.selectItem(at: selectedIndex)
        }
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        themePopup = popup
        appearance.addRow(SettingsRowView(
            title: "Theme",
            subtitle: "Applies to the app chrome and terminal colors.",
            control: popup,
            theme: currentTheme
        ))
        addContentSubview(appearance)

        let session = SettingsSectionView(title: "Session", theme: currentTheme)
        let toggle = ToggleSwitchView(isOn: settings.restoreLastSession, theme: currentTheme)
        toggle.onToggle = { [weak self] isOn in
            guard let self else { return }
            self.settings.restoreLastSession = isOn
            self.settings.save()
            self.onSettingsChanged?(self.settings)
        }
        restoreSessionToggle = toggle
        session.addRow(SettingsRowView(
            title: "Restore Last Session",
            subtitle: "Reopen the previous workspace on launch.",
            control: toggle,
            theme: currentTheme
        ))
        addContentSubview(session)

        let projects = SettingsSectionView(title: "Project Directories", theme: currentTheme)
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        projectDirectoriesStack = listStack
        projects.addRow(listStack)
        rebuildProjectDirectoriesList()

        let addRow = NSView()
        addRow.translatesAutoresizingMaskIntoConstraints = false
        let input = SettingsControls.themedField(value: "", theme: currentTheme)
        input.placeholderString = "Folder path"
        projectDirectoryInput = input
        let browseButton = SettingsControls.themedButton(
            title: "Browse", target: self, action: #selector(browseProjectDirectory), theme: currentTheme
        )
        let addButton = SettingsControls.themedButton(
            title: "Add", target: self, action: #selector(addProjectDirectory), theme: currentTheme
        )
        addRow.addSubview(input)
        addRow.addSubview(browseButton)
        addRow.addSubview(addButton)
        NSLayoutConstraint.activate([
            addRow.heightAnchor.constraint(equalToConstant: 44),
            input.leadingAnchor.constraint(equalTo: addRow.leadingAnchor, constant: 14),
            input.centerYAnchor.constraint(equalTo: addRow.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -8),
            browseButton.centerYAnchor.constraint(equalTo: addRow.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: addRow.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: addRow.trailingAnchor, constant: -14),
        ])
        projects.addRow(addRow)
        addContentSubview(projects)

        let keybinding = SettingsSectionView(title: "Keybinding Behavior", theme: currentTheme)

        let prefixField = SettingsControls.themedField(
            value: keybindingConfig.prefixKey, theme: currentTheme, width: 80
        )
        prefixField.target = self
        prefixField.action = #selector(prefixKeyCommitted(_:))
        prefixKeyField = prefixField
        keybinding.addRow(SettingsRowView(
            title: "Prefix Key",
            subtitle: "Held with Ctrl to start a prefix sequence.",
            control: prefixField,
            theme: currentTheme
        ))

        let timeoutField = SettingsControls.themedField(
            value: "\(keybindingConfig.prefixTimeoutMs)", theme: currentTheme, width: 80
        )
        timeoutField.target = self
        timeoutField.action = #selector(prefixTimeoutCommitted(_:))
        prefixTimeoutField = timeoutField
        keybinding.addRow(SettingsRowView(
            title: "Prefix Timeout (ms)",
            control: timeoutField,
            theme: currentTheme
        ))

        let resizeField = SettingsControls.themedField(
            value: "\(Int(keybindingConfig.resizeTickPercent))", theme: currentTheme, width: 80
        )
        resizeField.target = self
        resizeField.action = #selector(resizeStepCommitted(_:))
        resizeStepField = resizeField
        keybinding.addRow(SettingsRowView(
            title: "Resize Step (%)",
            control: resizeField,
            theme: currentTheme
        ))
        addContentSubview(keybinding)
    }
```

- [ ] **Step 3: Rewrite `rebuildProjectDirectoriesList`**

```swift
    private func rebuildProjectDirectoriesList() {
        guard let list = projectDirectoriesStack else { return }
        for row in list.arrangedSubviews {
            list.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        if settings.projectDirectories.isEmpty {
            let empty = SettingsRowView(
                title: "No project directories configured",
                theme: currentTheme
            )
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }

        for (index, directory) in settings.projectDirectories.enumerated() {
            let removeButton = SettingsControls.themedButton(
                title: "Remove", target: self, action: #selector(removeProjectDirectory(_:)), theme: currentTheme
            )
            removeButton.tag = index
            let row = SettingsRowView(
                title: (directory as NSString).lastPathComponent,
                subtitle: directory,
                control: removeButton,
                theme: currentTheme
            )
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
```

- [ ] **Step 4: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 5: Verify via harness**

Capture the General tab. Checklist: page header on top (title + one-line subtitle, no word-per-line wrapping); four grouped sections with uppercase mono labels (APPEARANCE, SESSION, PROJECT DIRECTORIES, KEYBINDING BEHAVIOR); hairline dividers between rows; themed toggle instead of checkbox; 80pt compact fields right-aligned; content no wider than 560pt.

Also verify the toggle works: `"$SCRATCH/driver" click` is unreliable in background, so use AX: there is no AX action on a plain NSView toggle — instead toggle-verification is manual/visual only at this stage (state renders per `settings.restoreLastSession`).

- [ ] **Step 6: Commit**

```bash
git add Sources/Soprano/Views/SettingsWindowController.swift
git commit -m "feat(settings): rebuild General tab with component kit"
```

---

### Task 4: Keyboard Shortcuts tab rebuild

**Files:**
- Modify: `Sources/Soprano/Views/SettingsWindowController.swift` (`buildKeyboardShortcutsTab` ~line 710; delete `makeShortcutRow` ~line 756)

**Interfaces:**
- Consumes: `SettingsSectionView`, `SettingsRowView`, `KeyBadgeView`, `SettingsControls.monoChip`, `SettingsControls.pageHeader`.
- Produces: nothing new.

- [ ] **Step 1: Rewrite `buildKeyboardShortcutsTab` and delete `makeShortcutRow`**

```swift
    private func buildKeyboardShortcutsTab() {
        addContentSubview(SettingsControls.pageHeader(
            title: "Keyboard Shortcuts",
            subtitle: "Read-only keybinding reference grouped by category.",
            theme: currentTheme
        ))

        let groups: [(title: String, category: KeyBindingCategory)] = [
            ("Navigation", .navigation),
            ("Layout & Splits", .layout),
            ("Agent Launchers", .agents),
            ("General", .general),
        ]

        for (groupTitle, category) in groups {
            let bindings = keybindingConfig.bindings.filter { $0.category == category }
            guard !bindings.isEmpty else { continue }
            let section = SettingsSectionView(title: groupTitle, theme: currentTheme)
            for binding in bindings {
                let trailing = NSStackView()
                trailing.orientation = .horizontal
                trailing.alignment = .centerY
                trailing.spacing = 10
                trailing.addArrangedSubview(SettingsControls.monoChip(
                    binding.mode == .direct ? "direct" : "prefix",
                    theme: currentTheme
                ))
                trailing.addArrangedSubview(KeyBadgeView(keys: binding.defaultKeys, theme: currentTheme))
                section.addRow(SettingsRowView(
                    title: binding.label,
                    subtitle: binding.description,
                    control: trailing,
                    theme: currentTheme
                ))
            }
            addContentSubview(section)
        }
    }
```

Delete the entire `makeShortcutRow(action:description:mode:keys:index:isHeader:)` method.

- [ ] **Step 2: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 3: Verify via harness**

Capture with `click button "Keyboard Shortcuts"`. Checklist: four grouped sections; each row shows binding label + muted description, right side shows muted PREFIX/DIRECT chip and a compact key badge that hugs its text (no stretching); no header row, no zebra striping.

- [ ] **Step 4: Commit**

```bash
git add Sources/Soprano/Views/SettingsWindowController.swift
git commit -m "feat(settings): rebuild Keyboard Shortcuts tab with component kit"
```

---

### Task 5: Agent Profiles tab rebuild

**Files:**
- Modify: `Sources/Soprano/Views/SettingsWindowController.swift` (`buildAgentProfilesTab` ~line 826; delete `makeAgentCard` ~line 861)

**Interfaces:**
- Consumes: `SettingsSectionView`, `SettingsRowView`, `SettingsControls.pageHeader`; `DefaultAgents.all`, `AgentProfile` (`nsColor`, `icon`, `name`, `description`, `command`, `args`).
- Produces: nothing new.

- [ ] **Step 1: Rewrite `buildAgentProfilesTab` and delete `makeAgentCard`**

```swift
    private func buildAgentProfilesTab() {
        addContentSubview(SettingsControls.pageHeader(
            title: "Agent Profiles",
            subtitle: "Read-only profile registry loaded from DefaultAgents.",
            theme: currentTheme
        ))

        let section = SettingsSectionView(title: "Profiles", theme: currentTheme)
        for profile in DefaultAgents.all {
            let trailing = NSStackView()
            trailing.orientation = .horizontal
            trailing.alignment = .centerY
            trailing.spacing = 8

            let command = NSTextField(
                labelWithString: "\(profile.command) \(profile.args.joined(separator: " "))"
                    .trimmingCharacters(in: .whitespaces)
            )
            command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            command.textColor = currentTheme.colors.textMuted
            command.lineBreakMode = .byTruncatingMiddle
            trailing.addArrangedSubview(command)

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = profile.nsColor.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            trailing.addArrangedSubview(dot)

            section.addRow(SettingsRowView(
                title: "\(profile.icon)  \(profile.name)",
                subtitle: profile.description,
                control: trailing,
                theme: currentTheme
            ))
        }
        addContentSubview(section)
    }
```

Delete the entire `makeAgentCard(_:)` method.

- [ ] **Step 2: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 3: Verify via harness**

Capture with `click button "Agent Profiles"`. Checklist: single PROFILES section; one row per agent with name + description on the left, muted mono command + color dot on the right; no 2-column cards, no pattern dumps.

- [ ] **Step 4: Commit**

```bash
git add Sources/Soprano/Views/SettingsWindowController.swift
git commit -m "feat(settings): rebuild Agent Profiles tab with component kit"
```

---

### Task 6: About tab rebuild + remove dead helpers

**Files:**
- Modify: `Sources/Soprano/Views/SettingsWindowController.swift` (`buildAboutTab` ~line 929; delete `makeTabHeader`, `makeSectionCard`, `makeFieldLabel`, `makeTextField`, `makeNumberField`, `makeActionButton`; remove the legacy `widthInset` path from `addContentSubview`)

**Interfaces:**
- Consumes: `SettingsSectionView`, `SettingsRowView`, `KeyBadgeView`; existing `quickReferenceBindings() -> [(String, String)]` (unchanged).
- Produces: final `addContentSubview(_ view: NSView)` signature without `widthInset`.

- [ ] **Step 1: Rewrite `buildAboutTab`**

```swift
    private func buildAboutTab() {
        let wordmark = NSView()
        wordmark.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "SOPRANO")
        title.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        title.textColor = currentTheme.colors.accent
        title.translatesAutoresizingMaskIntoConstraints = false
        wordmark.addSubview(title)

        let version = NSTextField(labelWithString: "Version 0.2.0")
        version.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        version.textColor = currentTheme.colors.textMuted
        version.translatesAutoresizingMaskIntoConstraints = false
        wordmark.addSubview(version)

        let runtime = NSTextField(labelWithString: "Swift + AppKit + libghostty")
        runtime.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        runtime.textColor = currentTheme.colors.textMuted
        runtime.translatesAutoresizingMaskIntoConstraints = false
        wordmark.addSubview(runtime)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: wordmark.leadingAnchor),
            title.topAnchor.constraint(equalTo: wordmark.topAnchor),
            version.leadingAnchor.constraint(equalTo: wordmark.leadingAnchor),
            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            runtime.leadingAnchor.constraint(equalTo: wordmark.leadingAnchor),
            runtime.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 2),
            runtime.bottomAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: -6),
        ])
        addContentSubview(wordmark)

        let quickRef = SettingsSectionView(title: "Quick Reference", theme: currentTheme)
        for (keys, label) in quickReferenceBindings() {
            quickRef.addRow(SettingsRowView(
                title: label,
                control: KeyBadgeView(keys: keys, theme: currentTheme),
                theme: currentTheme
            ))
        }
        addContentSubview(quickRef)
    }
```

- [ ] **Step 2: Delete dead helpers and the legacy width path**

Delete these now-unused methods entirely: `makeTabHeader(title:subtitle:)`, `makeSectionCard(title:subtitle:)`, `makeFieldLabel(_:)`, `makeTextField(value:)`, `makeNumberField(value:)`, `makeActionButton(title:action:)`.

Simplify `addContentSubview` to its final form:

```swift
    private func addContentSubview(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        let fill = view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48)
        fill.priority = .defaultHigh
        let cap = view.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        NSLayoutConstraint.activate([fill, cap])
    }
```

- [ ] **Step 3: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!` and no "unused" warnings for the deleted helpers. If the build fails with references to deleted helpers, a tab builder still uses one — fix that builder to use the Task 1 components instead.

- [ ] **Step 4: Verify via harness**

Capture with `click button "About"`. Checklist: compact accent SOPRANO wordmark (16pt, not a 34pt hero); Version and Runtime as two muted mono lines; QUICK REFERENCE section rows each with a compact key badge (⌘P badge must hug its text — this was the original stretching bug).

- [ ] **Step 5: Commit**

```bash
git add Sources/Soprano/Views/SettingsWindowController.swift
git commit -m "feat(settings): rebuild About tab, drop legacy card helpers"
```

---

### Task 7: Overlay chrome polish + full verification

**Files:**
- Modify: `Sources/Soprano/App/MainContentViewController.swift` (`loadView` settings header ~lines 83–96, `applyTheme` ~line 210)

**Interfaces:**
- Consumes: `SettingsControls.themedButton`.
- Produces: nothing new.

- [ ] **Step 1: Theme the embedded header's Done button**

In `MainContentViewController.loadView()`, replace the `settingsCloseButton` creation:

```swift
        settingsCloseButton = SettingsControls.themedButton(
            title: "Done",
            target: self,
            action: #selector(closeSettings),
            theme: themeManager.currentTheme
        )
        settingsHeaderView.addSubview(settingsCloseButton)
```

(The existing constraints for `settingsCloseButton` stay as they are.)

In `applyTheme()`, add after the existing settings styling lines:

```swift
        settingsCloseButton.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        settingsCloseButton.layer?.borderColor = theme.colors.borderSubtle.cgColor
        settingsCloseButton.attributedTitle = NSAttributedString(
            string: "Done",
            attributes: [
                .foregroundColor: theme.colors.textPrimary,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
        )
```

- [ ] **Step 2: Build**

Run: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 3: Full verification sweep**

Using the Verification Harness:

1. Capture all four tabs at the default window size; check each tab's checklist from Tasks 3–6.
2. Resize wide: `osascript -e 'tell application "System Events" to tell process "Soprano" to set size of window 1 to {1200, 800}'`, recapture General — sections must cap at 560pt, not stretch.
3. Theme switch: AX-select Catppuccin Mocha in the theme popup (`click pop up button 1 of window 1`, then `click menu item "Catppuccin Mocha" of menu 1 of pop up button 1 of window 1`), capture — every component must restyle (purple accent, new backgrounds). Switch back to Gruvbox Dark the same way.
4. Focus regression check: AX-press Done, then `"$SCRATCH/driver" text` + `key 36` an `echo FOCUS-OK` into the terminal, capture, confirm it executed.
5. `pkill -x Soprano`.

Expected: all checklists pass; screenshot set saved in the scratchpad.

- [ ] **Step 4: Commit**

```bash
git add Sources/Soprano/App/MainContentViewController.swift
git commit -m "feat(settings): theme the embedded settings header"
```
