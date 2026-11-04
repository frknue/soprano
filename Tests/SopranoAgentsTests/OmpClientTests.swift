import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpClient` against a real process that never writes omp's `ready` frame.
struct OmpClientTests {
    @Test func waitingForReadyEndsAtTheTimeoutWhenOmpNeverAnswers() async throws {
        let process = LineProcess(LineProcess.Configuration(executable: "/bin/sleep", arguments: ["5"], environment: [:], directory: NSTemporaryDirectory()))
        try process.start()
        defer { process.terminate() }
        let client = OmpClient(transport: process)
        let start = ContinuousClock.now

        await #expect(throws: ProviderError.timedOut("omp startup")) {
            try await withProviderTimeout(0.2, label: "omp startup") { try await client.ready() }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
