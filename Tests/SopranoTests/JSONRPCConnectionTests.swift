import AppKit
import Testing
@testable import Soprano

@MainActor
struct JSONRPCConnectionTests {
    /// `cat` echoes every line, so a request comes back as a request from the
    /// peer, and the reply to it comes back as the response to our request.
    @Test func requestsAndRepliesRoundTripAsNewlineDelimitedJSON() async throws {
        let connection = JSONRPCConnection(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], workingDirectory: nil, environment: nil
        )
        var received: [(String, JSONValue)] = []
        connection.onRequest = { method, params, reply in
            received.append((method, params))
            reply(.success(["echoed": params["text"] ?? .null]))
        }
        try connection.start()
        let result = try await connection.request("say", params: ["text": "hi \"there\"\nnext"])
        #expect(result == ["echoed": "hi \"there\"\nnext"])
        #expect(received.map(\.0) == ["say"])

        connection.terminate()
        await connection.waitForExit()
        await #expect(throws: JSONRPCError.closed) {
            try await connection.request("late", params: [:])
        }
    }

    @Test func anAgentThatIgnoresTerminationIsKilledAfterTheGracePeriod() async throws {
        let connection = JSONRPCConnection(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
            workingDirectory: nil,
            environment: nil,
            exitGracePeriod: 0.2
        )
        var exitStatus: Int32?
        connection.onExit = { status, _ in exitStatus = status }
        try connection.start()
        // Let the shell install its trap before the signal arrives.
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        connection.terminate()
        await connection.waitForExit()
        #expect(Date().timeIntervalSince(started) >= 0.2)
        #expect(exitStatus == SIGKILL)
    }
}
