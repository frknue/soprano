import AppKit
import Testing
@testable import SopranoAgentsCore

struct LineProcessTests {
    private static func shell(_ script: String) -> LineProcess.Configuration {
        LineProcess.Configuration(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    }

    private static func collect(_ process: LineProcess) async -> (lines: [String], status: Int32, stderr: String) {
        var lines: [String] = []
        for await event in process.events {
            switch event {
            case let .line(line): lines.append(line)
            case let .exited(status, stderr): return (lines, status, stderr)
            }
        }
        return (lines, -1, "")
    }

    @Test func linesArriveWholeEvenWhenWrittenInPiecesAndTheLastOneLacksANewline() async throws {
        let process = LineProcess(Self.shell(#"printf 'one\r\ntw'; sleep 0.1; printf 'o\n\nthree'"#))
        try process.start()
        let result = await Self.collect(process)
        #expect(result.lines == ["one", "two", "", "three"])
        #expect(result.status == 0)
    }

    @Test func aMegabyteLongLineIsDeliveredIntact() async throws {
        let process = LineProcess(Self.shell("head -c 1048576 /dev/zero | tr '\\0' 'x'; echo; echo end"))
        try process.start()
        let result = await Self.collect(process)
        #expect(result.lines.count == 2)
        #expect(result.lines.first?.count == 1_048_576)
        #expect(result.lines.last == "end")
    }

    @Test func stdinLinesRoundTripAndStderrIsKeptForErrorMessages() async throws {
        let process = LineProcess(Self.shell("while read line; do echo \"got $line\"; done; echo 'bad things' >&2; exit 3"))
        try process.start()
        try process.send(#"{"id":1}"#)
        try process.send(#"{"id":2}"#)
        process.closeInput()
        let result = await Self.collect(process)
        #expect(result.lines == [#"got {"id":1}"#, #"got {"id":2}"#])
        #expect(result.status == 3)
        #expect(result.stderr == "bad things\n")
        #expect(throws: LineProcessError.notRunning) { try process.send("late") }
    }

    @Test func stderrKeepsOnlyTheLast64KB() async throws {
        let process = LineProcess(Self.shell("head -c 200000 /dev/zero | tr '\\0' 'e' >&2; printf 'TAIL' >&2"))
        try process.start()
        let result = await Self.collect(process)
        #expect(result.stderr.utf8.count == LineProcess.stderrLimit)
        #expect(result.stderr.hasSuffix("TAIL"))
    }

    @Test func terminateEndsTheWholeProcessGroupIncludingChildren() async throws {
        let process = LineProcess(Self.shell("sleep 30 & echo $!; wait"))
        try process.start()
        var iterator = process.events.makeAsyncIterator()
        guard case let .line(childLine)? = await iterator.next(), let child = Int32(childLine) else {
            Issue.record("expected the child pid")
            return
        }
        #expect(kill(child, 0) == 0)
        process.terminate()
        var status: Int32?
        while let event = await iterator.next() {
            if case let .exited(code, _) = event { status = code }
        }
        #expect(status == 128 + SIGTERM)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(kill(child, 0) == -1)
    }

    @Test func aChildIgnoringSigtermIsKilledAfterTheGraceEvenWhenTheLeaderHasAlreadyExited() async throws {
        let process = LineProcess(Self.shell("(trap '' TERM; exec sleep 30 >/dev/null 2>&1) & echo $!; wait"))
        try process.start()
        var iterator = process.events.makeAsyncIterator()
        guard case let .line(childLine)? = await iterator.next(), let child = Int32(childLine) else {
            Issue.record("expected the child pid")
            return
        }
        defer { kill(child, SIGKILL) }
        process.terminate()
        while await iterator.next() != nil {}
        let deadline = ContinuousClock.now + .seconds(LineProcess.killGrace + 5)
        while kill(child, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(kill(child, 0) == -1)
    }

    @Test func aMissingExecutableFailsToStart() {
        let process = LineProcess(LineProcess.Configuration(executable: "/nonexistent/omp", arguments: [], environment: [:]))
        #expect(throws: LineProcessError.self) { try process.start() }
    }

    @Test func runCollectsOutputAndTimesOutHangingProcesses() async throws {
        let output = try await LineProcess.run(Self.shell("cat; echo done"), input: "prompt text", timeout: 10, label: "Echo")
        #expect(output.stdout == "prompt text\ndone")
        #expect(output.status == 0)

        await #expect(throws: ProviderError.timedOut("Sleep")) {
            _ = try await LineProcess.run(Self.shell("sleep 30"), timeout: 0.3, label: "Sleep")
        }
    }

    @Test func cancellingRunThrowsCancellationRatherThanATimeout() async throws {
        let run = Task { try await LineProcess.run(Self.shell("sleep 30"), timeout: 30, label: "Sleep") }
        try await Task.sleep(nanoseconds: 200_000_000)
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
    }

    @Test func runsInTheConfiguredDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("line-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Self.shell("pwd -P")
        configuration.directory = directory.path
        let output = try await LineProcess.run(configuration, timeout: 10, label: "pwd")
        #expect(output.stdout == URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().path
            || output.stdout == "/private" + directory.path)
    }
}
