import AppKit
import Testing
@testable import SopranoAgentsCore

struct ProviderCommandTests {
    @Test func theMenuListsEachInsertOnceWithCommandsBeforeSkillsAlphabetically() {
        let list = ProviderCommand.normalized([
            ProviderCommand(name: "skill:tdd", kind: .skill, source: "Skill", insertText: "/skill:tdd "),
            ProviderCommand(name: "review", kind: .command, source: "Custom", insertText: "/review "),
            ProviderCommand(name: "Compact", kind: .command, source: "Built-in", insertText: "/compact "),
            ProviderCommand(name: "review", kind: .command, source: "Built-in", insertText: "/review "),
            ProviderCommand(name: "skill:agents-md", kind: .skill, source: "Skill", insertText: "/skill:agents-md "),
            ProviderCommand(name: "model", kind: .command, source: "Built-in", insertText: "/model "),
        ])

        #expect(list.map(\.insertText) == ["/compact ", "/model ", "/review ", "/skill:agents-md ", "/skill:tdd "])
        // The first entry for an insert wins.
        #expect(list.first { $0.insertText == "/review " }?.source == "Custom")
    }

    @Test func providerSourcesBecomeShortBadges() {
        let sources: [String?] = ["builtin", "skill", "extension", "mcp_prompt", "custom", "file", "prompt", nil]

        #expect(sources.map(ProviderCommand.badge(forSource:)) == ["Built-in", "Skill", "Extension", "MCP", "Custom", "Custom", nil, nil])
    }
}
