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
        case .osc52Read, .osc52Write:
            "Authorize Clipboard Access"
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
        queue.append(Request(
            surface: surface,
            prompt: ClipboardConfirmationPrompt(kind: kind, content: content),
            parentWindow: parentWindow,
            resolve: resolve
        ))
        presentNextIfNeeded()
    }

    func cancelRequests(for surface: ObjectIdentifier) {
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

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.allowButtonTitle)
        alert.addButton(withTitle: prompt.denyButtonTitle)
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.accessoryView = makePreview(content: prompt.content)

        let presentation = AppKitClipboardConfirmationPresentation(
            alert: alert,
            parentWindow: parentWindow,
            completion: completion
        )
        presentation.begin()
        return presentation
    }

    private func makePreview(content: String) -> NSScrollView {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = frame
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = content
        scrollView.documentView = textView

        return scrollView
    }
}

@MainActor
private final class EmptyClipboardConfirmationPresentation: ClipboardConfirmationPresentation {
    func dismiss() {}
}

@MainActor
private final class AppKitClipboardConfirmationPresentation: ClipboardConfirmationPresentation {
    private let alert: NSAlert
    private weak var parentWindow: NSWindow?
    private var completion: ((ClipboardConfirmationDecision) -> Void)?

    init(
        alert: NSAlert,
        parentWindow: NSWindow,
        completion: @escaping (ClipboardConfirmationDecision) -> Void
    ) {
        self.alert = alert
        self.parentWindow = parentWindow
        self.completion = completion
    }

    func begin() {
        guard let parentWindow else {
            finish(with: .dismissed)
            return
        }

        alert.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self else { return }
            finish(with: response == .alertFirstButtonReturn ? .allow : .deny)
        }
    }

    func dismiss() {
        guard completion != nil else { return }
        guard let parentWindow, alert.window.sheetParent != nil else {
            finish(with: .dismissed)
            return
        }
        parentWindow.endSheet(alert.window, returnCode: .abort)
    }

    private func finish(with decision: ClipboardConfirmationDecision) {
        guard let completion else { return }
        self.completion = nil
        completion(decision)
    }
}
