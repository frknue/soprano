import CoreServices
import Foundation

/// Recursive watcher for directory trees, built on FSEvents. FSEvents
/// coalesces bursts within `latency`; batches arrive on the main queue as the
/// changed paths (fully symlink-resolved) plus whether events were dropped
/// and the trees need a full rescan. Main-thread-only like the other managers.
final class FileSystemWatcher: @unchecked Sendable {
    typealias Handler = @MainActor (_ paths: [String], _ needsRescan: Bool) -> Void

    let paths: [String]
    private let handler: Handler
    private var stream: FSEventStreamRef?

    init?(paths: [String], latency: TimeInterval = 0.15, handler: @escaping Handler) {
        self.paths = paths
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileSystemWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        let needsRescan = flags.contains { $0 & rescanFlags != 0 }
        let handler = handler
        MainActor.assumeIsolated {
            handler(paths, needsRescan)
        }
    }
}

private func fileSystemWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
    watcher.deliver(paths: paths, flags: flags)
}
