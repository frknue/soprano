import AppKit
import Testing
@testable import SopranoAgentsCore

struct CodexAppServerClientTests {
    /// In-memory transport: records what the client sends, replays what the test pushes.
    private final class FakeTransport: JSONLineTransport, @unchecked Sendable {
        let incoming: AsyncStream<LineProcessEvent>
        private let continuation: AsyncStream<LineProcessEvent>.Continuation
        private let lock = NSLock()
        private var lines: [String] = []

        init() {
            (incoming, continuation) = AsyncStream.makeStream(of: LineProcessEvent.self)
        }

        var sent: [JSONValue] { lock.withLock { lines.compactMap { try? JSONValue.parse($0) } } }
        func send(_ line: String) throws { lock.withLock { lines.append(line) } }
        func close() { exit(status: 143) }
        func push(_ line: String) { continuation.yield(.line(line)) }
        func exit(status: Int32, stderr: String = "") {
            continuation.yield(.exited(status: status, stderr: stderr))
            continuation.finish()
        }

        /// Waits until the client has sent `count` lines.
        func waitForSent(_ count: Int) async {
            for _ in 0..<500 where sent.count < count { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    @Test func responsesResolveTheirOwnRequestsEvenWhenTheyArriveOutOfOrder() async throws {
        let transport = FakeTransport()
        let client = CodexAppServerClient(transport: transport)
        async let first = client.request("account/read", params: [:])
        async let second = client.request("model/list", params: ["cursor": "c2"])
        await transport.waitForSent(2)

        let sent = transport.sent
        #expect(sent.allSatisfy { $0["jsonrpc"] == nil })
        let idsByMethod = Dictionary(uniqueKeysWithValues: sent.map { ($0["method"]?.stringValue ?? "", $0["id"] ?? .null) })
        transport.push(#"{"id":\#(idsByMethod["model/list"]!.jsonString()),"result":{"data":[],"nextCursor":null}}"#)
        transport.push(#"{"id":\#(idsByMethod["account/read"]!.jsonString()),"result":{"account":null,"requiresOpenaiAuth":true}}"#)

        #expect(try await second == ["data": [], "nextCursor": nil])
        #expect(try await first == ["account": nil, "requiresOpenaiAuth": true])
    }

    @Test func errorResponsesThrowWithTheServerMessage() async throws {
        let transport = FakeTransport()
        let client = CodexAppServerClient(transport: transport)
        let result = Task { try await client.request("thread/resume", params: ["threadId": "x"]) }
        await transport.waitForSent(1)
        transport.push(#"{"id":1,"error":{"code":-32600,"message":"session x is archived"}}"#)
        await #expect(throws: ProviderError.rpc(method: "thread/resume", code: -32600, message: "session x is archived")) {
            try await result.value
        }
    }

    @Test func serverRequestsKeepStringIdsAndAnswersEchoThem() async throws {
        let transport = FakeTransport()
        let client = CodexAppServerClient(transport: transport)
        transport.push(#"{"method":"item/commandExecution/requestApproval","id":"abc-1","params":{"itemId":"exec-1"}}"#)
        transport.push(#"{"method":"turn/started","params":{"turn":{"id":"t1"}}}"#)

        var iterator = client.incoming.makeAsyncIterator()
        let request = await iterator.next()
        #expect(request == .request(id: .string("abc-1"), method: "item/commandExecution/requestApproval", params: ["itemId": "exec-1"]))
        #expect(await iterator.next() == .notification(method: "turn/started", params: ["turn": ["id": "t1"]]))

        await client.respond(to: .string("abc-1"), result: ["decision": "accept"])
        await client.respond(to: .number(0), errorCode: -32601, message: "unsupported")
        #expect(transport.sent == [
            ["id": "abc-1", "result": ["decision": "accept"]],
            ["id": 0, "error": ["code": -32601, "message": "unsupported"]],
        ])
    }

    @Test func aClosedTransportFailsPendingRequestsAndEndsTheIncomingStream() async throws {
        let transport = FakeTransport()
        let client = CodexAppServerClient(transport: transport)
        let result = Task { try await client.request("turn/start", params: [:]) }
        await transport.waitForSent(1)
        transport.exit(status: 1, stderr: "panic: boom\n")

        await #expect(throws: ProviderError.processExited(.codex, status: 1, stderr: "panic: boom\n")) {
            try await result.value
        }
        var messages: [CodexAppServerClient.Incoming] = []
        for await message in client.incoming { messages.append(message) }
        #expect(messages == [.closed(status: 1, stderr: "panic: boom\n")])
        await #expect(throws: ProviderError.self) {
            try await client.request("turn/interrupt", params: [:])
        }
    }

    @Test func nonJSONOutputLinesAreIgnored() async throws {
        let transport = FakeTransport()
        let client = CodexAppServerClient(transport: transport)
        transport.push("WARN starting app-server")
        transport.push(#"{"method":"thread/started","params":{}}"#)
        var iterator = client.incoming.makeAsyncIterator()
        #expect(await iterator.next() == .notification(method: "thread/started", params: [:]))
    }
}
