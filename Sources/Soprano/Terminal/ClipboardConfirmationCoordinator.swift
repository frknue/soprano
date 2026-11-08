import AppKit

enum ClipboardConfirmationKind: Equatable {
    case paste
    case osc52Read
    case osc52Write
}

struct ClipboardConfirmationPrompt: Equatable {
    let kind: ClipboardConfirmationKind
    let content: String

    var title: String {
        switch kind {
        case .paste:
            "Warning: Potentially Unsafe Paste"
        case .osc52Read:
            "Authorize Clipboard Read"
        case .osc52Write:
            "Authorize Clipboard Write"
        }
    }

    var message: String {
        switch kind {
        case .paste:
            "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
        case .osc52Read:
            """
            An application is attempting to read from the clipboard.
            The current clipboard contents are shown below.
            """
        case .osc52Write:
            """
            An application is attempting to write to the clipboard.
            The content to write is shown below.
            """
        }
    }

    var allowButtonTitle: String {
        switch kind {
        case .paste:
            "Paste"
        case .osc52Read, .osc52Write:
            "Allow"
        }
    }

    var denyButtonTitle: String {
        switch kind {
        case .paste:
            "Cancel"
        case .osc52Read, .osc52Write:
            "Deny"
        }
    }
}

enum ClipboardConfirmationDecision {
    case allow
    case deny
    case dismissed
}

@MainActor
protocol ClipboardConfirmationPresentation: AnyObject {
    func dismiss()
}

@MainActor
protocol ClipboardConfirmationPresenting: AnyObject {
    func present(
        _ prompt: ClipboardConfirmationPrompt,
        from parentWindow: NSWindow?,
        completion: @escaping (ClipboardConfirmationDecision) -> Void
    ) -> any ClipboardConfirmationPresentation
}

@MainActor
final class ClipboardConfirmationCoordinator {
    private struct Request {
        let id = UUID()
        let surface: ObjectIdentifier
        let prompt: ClipboardConfirmationPrompt
        let parentWindow: NSWindow?
        let resolve: (Bool) -> Void
    }

    private final class ActiveRequest {
        let request: Request
        var presentation: (any ClipboardConfirmationPresentation)?

        init(request: Request) {
            self.request = request
        }
    }

    private let presenter: any ClipboardConfirmationPresenting
    private var queue: [Request] = []
    private var active: ActiveRequest?
    private var cancelingSurfaces: Set<ObjectIdentifier> = []

    init(presenter: any ClipboardConfirmationPresenting) {
        self.presenter = presenter
    }

    func enqueue(
        surface: ObjectIdentifier,
        kind: ClipboardConfirmationKind,
        content: String,
        parentWindow: NSWindow?,
        resolve: @escaping (Bool) -> Void
    ) {
        guard !cancelingSurfaces.contains(surface) else {
            resolve(false)
            return
        }

        queue.append(Request(
            surface: surface,
            prompt: ClipboardConfirmationPrompt(kind: kind, content: content),
            parentWindow: parentWindow,
            resolve: resolve
        ))
        presentNextIfNeeded()
    }

    func cancelRequests(for surface: ObjectIdentifier) {
        guard cancelingSurfaces.insert(surface).inserted else { return }

        let activeToCancel: ActiveRequest?
        if active?.request.surface == surface {
            activeToCancel = active
            active = nil
        } else {
            activeToCancel = nil
        }

        var queuedToCancel: [Request] = []
        queue.removeAll { request in
            guard request.surface == surface else { return false }
            queuedToCancel.append(request)
            return true
        }

        if let activeToCancel {
            activeToCancel.request.resolve(false)
            activeToCancel.presentation?.dismiss()
        }
        for request in queuedToCancel {
            request.resolve(false)
        }

        cancelingSurfaces.remove(surface)
        presentNextIfNeeded()
    }

    private func presentNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }

        let request = queue.removeFirst()
        let activeRequest = ActiveRequest(request: request)
        active = activeRequest

        let presentation = presenter.present(
            request.prompt,
            from: request.parentWindow
        ) { [weak self] decision in
            self?.complete(requestID: request.id, decision: decision)
        }

        if active?.request.id == request.id {
            activeRequest.presentation = presentation
        }
    }

    private func complete(
        requestID: UUID,
        decision: ClipboardConfirmationDecision
    ) {
        guard let active, active.request.id == requestID else { return }
        self.active = nil
        active.request.resolve(decision == .allow)
        presentNextIfNeeded()
    }
}

/// Presents the confirmation as a `ShellDialogs` dialog with the content in a preview:
/// deny (Esc, a click outside) on the left, allow (Return) on the right.
@MainActor
final class AppKitClipboardConfirmationPresenter: ClipboardConfirmationPresenting {
    func present(
        _ prompt: ClipboardConfirmationPrompt,
        from parentWindow: NSWindow?,
        completion: @escaping (ClipboardConfirmationDecision) -> Void
    ) -> any ClipboardConfirmationPresentation {
        guard let parentWindow else {
            completion(.dismissed)
            return EmptyClipboardConfirmationPresentation()
        }

        let presentation = DialogClipboardConfirmationPresentation(completion: completion)
        presentation.controller = ShellDialogs.choose(
            title: prompt.title,
            message: prompt.message,
            buttons: [
                ShellDialogButton(prompt.denyButtonTitle, keyEquivalent: "\u{1b}"),
                ShellDialogButton(prompt.allowButtonTitle, style: .primary),
            ],
            accessory: ClipboardPreviewView(content: prompt.content),
            in: parentWindow
        ) { index in
            // Held until answered; finishing clears the controller and so the cycle.
            presentation.finish(with: index == 1 ? .allow : .deny)
        }
        return presentation
    }
}

/// The clipboard content in a read-only, scrolling code block (`rounded-lg border
/// bg-code font-mono`), as tall as the text up to `maxHeight`.
final class ClipboardPreviewView: PaletteView {
    static let maxHeight: CGFloat = 220
    private static let minHeight: CGFloat = 44
    private static let inset = NSSize(width: 10, height: 8)

    let textView: NSTextView
    private let scrollView: NSScrollView

    init(content: String, width: CGFloat = ShellDialogController.width - 48) {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView ?? NSTextView()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.maxHeight))
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = Typography.mono()
        textView.textContainerInset = Self.inset
        textView.string = content
        addSubview(scrollView)

        let height = Self.height(of: textView, width: width)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        frame.size.height = height
        applyPalette(palette)
    }

    /// The text's wrapped height plus insets and border, between `minHeight` and `maxHeight`.
    private static func height(of textView: NSTextView, width: CGFloat) -> CGFloat {
        let padding = (textView.textContainer?.lineFragmentPadding ?? 5) * 2
        let textWidth = width - inset.width * 2 - padding - 2
        let font = textView.font ?? Typography.mono()
        // A trailing newline still takes a line in the view.
        let text = textView.string.hasSuffix("\n") ? textView.string + " " : textView.string
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let total = ceil(bounds.height) + inset.height * 2 + 2
        return min(max(total, minHeight), maxHeight)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.codeBackground.cgColor
        layer?.borderColor = palette.border.cgColor
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.foreground
    }
}

@MainActor
private final class EmptyClipboardConfirmationPresentation: ClipboardConfirmationPresentation {
    func dismiss() {}
}

@MainActor
private final class DialogClipboardConfirmationPresentation: ClipboardConfirmationPresentation {
    /// The shown dialog; nil once answered, or when the system-alert fallback answered it.
    var controller: ShellDialogController?
    private var completion: ((ClipboardConfirmationDecision) -> Void)?

    init(completion: @escaping (ClipboardConfirmationDecision) -> Void) {
        self.completion = completion
    }

    /// Closes the dialog unanswered (its terminal went away).
    func dismiss() {
        guard let completion else { return }
        self.completion = nil
        controller?.finish(index: nil)
        controller = nil
        completion(.dismissed)
    }

    func finish(with decision: ClipboardConfirmationDecision) {
        guard let completion else { return }
        self.completion = nil
        controller = nil
        completion(decision)
    }
}
