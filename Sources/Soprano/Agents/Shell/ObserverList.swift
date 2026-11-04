/// Change handlers keyed by owner. An owner's handlers stop firing once the
/// owner is deallocated, so views register `[weak self]` handlers and never
/// have to unregister.
@MainActor
final class ObserverList<Value> {
    private struct Entry {
        weak var owner: AnyObject?
        let handler: @MainActor (Value) -> Void
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.allSatisfy { $0.owner == nil } }

    func add(_ owner: AnyObject, _ handler: @escaping @MainActor (Value) -> Void) {
        entries.append(Entry(owner: owner, handler: handler))
    }

    func remove(_ owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
    }

    func notify(_ value: Value) {
        entries.removeAll { $0.owner == nil }
        // Handlers may add or remove observers; iterate over a snapshot.
        for entry in entries where entry.owner != nil {
            entry.handler(value)
        }
    }
}
