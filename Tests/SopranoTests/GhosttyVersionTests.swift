import AppKit
import Testing
import GhosttyKit

/// Guards the one coupling git cannot express: `lib/libghostty.a` is not tracked, so nothing
/// else notices when the linked library stops matching the ghostty commit this checkout is
/// built against. `Support/ghostty-version.txt` records that version and
/// `scripts/build-ghostty.sh` rewrites it, so a stale or hand-copied library fails here
/// rather than surfacing as a struct-layout mismatch at runtime.
struct GhosttyVersionTests {
    @Test func theLinkedLibghosttyReportsTheVersionRecordedForThisCheckout() throws {
        let recorded = try recordedGhosttyVersion()

        #expect(
            linkedGhosttyVersion() == recorded,
            """
            Linked libghostty.a is \(linkedGhosttyVersion()) but this checkout records \
            \(recorded). Rebuild with scripts/build-ghostty.sh so lib/libghostty.a, \
            Sources/GhosttyKit/include/ghostty.h, and Support/ghostty-version.txt all come \
            from one ghostty build.
            """
        )
    }

    @Test func theRecordedVersionIsASingleNonEmptyLine() throws {
        let recorded = try recordedGhosttyVersion()

        #expect(!recorded.isEmpty)
        #expect(!recorded.contains("\n"))
    }

    @Test func theHeaderTheModuleIsBuiltAgainstIsCheckedIn() {
        let header = repositoryRoot.appendingPathComponent("Sources/GhosttyKit/include/ghostty.h")

        #expect(FileManager.default.fileExists(atPath: header.path))
    }

    // MARK: - Sources of truth

    /// The version compiled into the static library actually being linked.
    private func linkedGhosttyVersion() -> String {
        let info = ghostty_info()

        return String(
            decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)),
            as: UTF8.self
        )
    }

    private func recordedGhosttyVersion() throws -> String {
        let url = repositoryRoot.appendingPathComponent("Support/ghostty-version.txt")

        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Tests/SopranoTests/GhosttyVersionTests.swift` → repository root.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
