import AppKit
import Testing
@testable import Soprano

@MainActor
struct ClipboardConfirmationCoordinatorTests {
    @Test func presentsRequestsInFIFOOrder() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let identity = SurfaceIdentity()
        let surface = ObjectIdentifier(identity)
        var resolutions: [String] = []

        coordinator.enqueue(
            surface: surface,
            kind: .paste,
            content: "first",
            parentWindow: nil
        ) { allowed in
            resolutions.append("first:\(allowed)")
        }
        coordinator.enqueue(
            surface: surface,
            kind: .osc52Read,
            content: "second",
            parentWindow: nil
        ) { allowed in
            resolutions.append("second:\(allowed)")
        }

        #expect(presenter.prompts.map(\.content) == ["first"])

        presenter.completePresentation(at: 0, with: .allow)

        #expect(presenter.prompts.map(\.content) == ["first", "second"])
        #expect(resolutions == ["first:true"])

        presenter.completePresentation(at: 1, with: .deny)

        #expect(resolutions == ["first:true", "second:false"])
    }

    @Test func allowAndDenyResolveWithTheirPolicyValues() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let identity = SurfaceIdentity()
        let surface = ObjectIdentifier(identity)
        var resolutions: [Bool] = []

        coordinator.enqueue(
            surface: surface,
            kind: .osc52Read,
            content: "read",
            parentWindow: nil,
            resolve: { resolutions.append($0) }
        )
        coordinator.enqueue(
            surface: surface,
            kind: .osc52Write,
            content: "write",
            parentWindow: nil,
            resolve: { resolutions.append($0) }
        )

        presenter.completePresentation(at: 0, with: .allow)
        presenter.completePresentation(at: 1, with: .deny)

        #expect(resolutions == [true, false])
    }

    @Test func dismissalIsAdenial() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let identity = SurfaceIdentity()
        let surface = ObjectIdentifier(identity)
        var resolution: Bool?

        coordinator.enqueue(
            surface: surface,
            kind: .paste,
            content: "content",
            parentWindow: nil,
            resolve: { resolution = $0 }
        )
        presenter.completePresentation(at: 0, with: .dismissed)

        #expect(resolution == false)
    }

    @Test func cancellationDeniesOnlyMatchingSurfaceAndContinuesFIFOQueue() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let firstIdentity = SurfaceIdentity()
        let secondIdentity = SurfaceIdentity()
        let firstSurface = ObjectIdentifier(firstIdentity)
        let secondSurface = ObjectIdentifier(secondIdentity)
        var resolutions: [String] = []

        coordinator.enqueue(
            surface: firstSurface,
            kind: .paste,
            content: "first-active",
            parentWindow: nil,
            resolve: { resolutions.append("first-active:\($0)") }
        )
        coordinator.enqueue(
            surface: secondSurface,
            kind: .osc52Read,
            content: "second",
            parentWindow: nil,
            resolve: { resolutions.append("second:\($0)") }
        )
        coordinator.enqueue(
            surface: firstSurface,
            kind: .osc52Read,
            content: "first-queued",
            parentWindow: nil,
            resolve: { resolutions.append("first-queued:\($0)") }
        )

        coordinator.cancelRequests(for: firstSurface)

        #expect(presenter.presentations[0].dismissCount == 1)
        #expect(presenter.prompts.map(\.content) == ["first-active", "second"])
        #expect(resolutions == ["first-active:false", "first-queued:false"])

        presenter.completePresentation(at: 0, with: .allow)
        #expect(resolutions == ["first-active:false", "first-queued:false"])

        presenter.completePresentation(at: 1, with: .allow)

        #expect(resolutions == ["first-active:false", "first-queued:false", "second:true"])
    }

    @Test func eachRequestResolvesExactlyOnce() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let identity = SurfaceIdentity()
        let surface = ObjectIdentifier(identity)
        var resolutionCount = 0

        coordinator.enqueue(
            surface: surface,
            kind: .osc52Read,
            content: "read",
            parentWindow: nil
        ) { _ in
            resolutionCount += 1
        }

        presenter.completePresentation(at: 0, with: .allow)
        presenter.completePresentation(at: 0, with: .deny)
        coordinator.cancelRequests(for: surface)

        #expect(resolutionCount == 1)
    }

    @Test func reentrantRequestForCancelingSurfaceIsDeniedSynchronously() {
        let presenter = ClipboardPresenterSpy()
        let coordinator = ClipboardConfirmationCoordinator(presenter: presenter)
        let identity = SurfaceIdentity()
        let surface = ObjectIdentifier(identity)
        var resolutions: [String] = []

        coordinator.enqueue(
            surface: surface,
            kind: .osc52Read,
            content: "original",
            parentWindow: nil
        ) { allowed in
            resolutions.append("original:\(allowed)")
            coordinator.enqueue(
                surface: surface,
                kind: .osc52Read,
                content: "reentrant",
                parentWindow: nil
            ) { reentrantAllowed in
                resolutions.append("reentrant:\(reentrantAllowed)")
            }
        }

        coordinator.cancelRequests(for: surface)

        #expect(presenter.prompts.map(\.content) == ["original"])
        #expect(resolutions == ["original:false", "reentrant:false"])
    }

    @Test func requestKindsHaveDistinctNativeTitlesAndMessages() {
        let paste = ClipboardConfirmationPrompt(kind: .paste, content: "")
        let read = ClipboardConfirmationPrompt(kind: .osc52Read, content: "")
        let write = ClipboardConfirmationPrompt(kind: .osc52Write, content: "")

        #expect(paste.title == "Warning: Potentially Unsafe Paste")
        #expect(
            paste.message
                == "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
        )
        #expect(read.title == "Authorize Clipboard Read")
        #expect(
            read.message == """
            An application is attempting to read from the clipboard.
            The current clipboard contents are shown below.
            """
        )
        #expect(write.title == "Authorize Clipboard Write")
        #expect(
            write.message == """
            An application is attempting to write to the clipboard.
            The content to write is shown below.
            """
        )
        #expect(Set([paste.title, read.title, write.title]).count == 3)
    }
}

@MainActor
private final class ClipboardPresenterSpy: ClipboardConfirmationPresenting {
    final class Presentation: ClipboardConfirmationPresentation {
        var dismissCount = 0

        func dismiss() {
            dismissCount += 1
        }
    }

    struct PendingPresentation {
        let prompt: ClipboardConfirmationPrompt
        let completion: (ClipboardConfirmationDecision) -> Void
        let presentation: Presentation
    }

    private(set) var pending: [PendingPresentation] = []

    var prompts: [ClipboardConfirmationPrompt] {
        pending.map(\.prompt)
    }

    var presentations: [Presentation] {
        pending.map(\.presentation)
    }

    func present(
        _ prompt: ClipboardConfirmationPrompt,
        from parentWindow: NSWindow?,
        completion: @escaping (ClipboardConfirmationDecision) -> Void
    ) -> ClipboardConfirmationPresentation {
        let presentation = Presentation()
        pending.append(PendingPresentation(
            prompt: prompt,
            completion: completion,
            presentation: presentation
        ))
        return presentation
    }

    func completePresentation(
        at index: Int,
        with decision: ClipboardConfirmationDecision
    ) {
        pending[index].completion(decision)
    }
}

private final class SurfaceIdentity {}
