import AppKit
import Testing
@testable import Soprano

@MainActor
struct ObserverListTests {
    private final class Owner {}

    @Test func handlersStopFiringOnceTheirOwnerIsDeallocated() {
        let list = ObserverList<Int>()
        var received: [String] = []
        let kept = Owner()
        var dropped: Owner? = Owner()
        list.add(kept) { received.append("kept \($0)") }
        list.add(dropped!) { received.append("dropped \($0)") }

        list.notify(1)
        dropped = nil
        list.notify(2)

        #expect(received == ["kept 1", "dropped 1", "kept 2"])
    }

    @Test func removingAnOwnerDropsOnlyThatOwnersHandlers() {
        let list = ObserverList<Int>()
        var received: [String] = []
        let first = Owner()
        let second = Owner()
        list.add(first) { received.append("first \($0)") }
        list.add(second) { received.append("second \($0)") }

        list.remove(first)
        list.notify(7)

        #expect(received == ["second 7"])
    }
}
