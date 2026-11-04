import AppKit
import Testing
@testable import Soprano

struct LaunchDispatchTests {
    private let paneEnvironment = ["SOPRANO_APP_PID": "4242"]

    @Test func aBareLaunchAndAppKitOrLaunchServicesArgumentsStillStartTheApp() {
        #expect(LaunchDispatch.decide(arguments: ["Soprano"], environment: [:]) == .startApp)
        #expect(LaunchDispatch.decide(
            arguments: ["Soprano", "-NSDocumentRevisionsDebugMode", "YES"],
            environment: [:]
        ) == .startApp)
        #expect(LaunchDispatch.decide(arguments: ["Soprano", "-psn_0_12345"], environment: [:]) == .startApp)
    }

    @Test func unknownSubcommandsAndPathsPrintUsageInsteadOfStartingASecondApp() {
        #expect(LaunchDispatch.decide(arguments: ["soprano", "notes.txt"], environment: [:]) == .usageError)
        #expect(LaunchDispatch.decide(arguments: ["soprano", "brwoser", "open"], environment: [:]) == .usageError)
        #expect(LaunchDispatch.decide(arguments: ["soprano", "--version"], environment: [:]) == .usageError)
        #expect(LaunchDispatch.decide(arguments: ["soprano", "--help"], environment: [:]) == .help)
        #expect(LaunchDispatch.decide(arguments: ["soprano", "-h"], environment: paneEnvironment) == .help)
    }

    @Test func anyUnclaimedCallOfTheOwningAppInsideASopranoTerminalNeverStartsIt() {
        #expect(LaunchDispatch.decide(arguments: ["soprano"], environment: paneEnvironment) == .usageError)
        #expect(LaunchDispatch.decide(
            arguments: ["soprano", "-NSDocumentRevisionsDebugMode", "YES"],
            environment: paneEnvironment
        ) == .usageError)
        #expect(LaunchDispatch.decide(arguments: ["soprano"], environment: ["SOPRANO_APP_PID": ""]) == .startApp)
    }

    @Test func anotherBuildStartedFromASopranoTerminalStartsLikeOutsideOne() {
        // `.build/debug/Soprano` run in a pane of the installed app (AGENTS.md: debugging).
        let other = LaunchDispatch.decide(arguments: ["Soprano"], environment: paneEnvironment, runsOwningApp: false)
        #expect(other == .startApp)
        #expect(LaunchDispatch.decide(
            arguments: ["Soprano", "notes.txt"], environment: paneEnvironment, runsOwningApp: false
        ) == .usageError)
    }

    @Test func theOwningAppIsRecognizedThroughThePanesSymlinkedSopranoCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("Soprano.app/Contents/MacOS")
        let bin = root.appendingPathComponent("Soprano.app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("Soprano")
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("soprano").path, withDestinationPath: "../../MacOS/Soprano"
        )
        let pane = ["SOPRANO_APP_PID": "4242", "SOPRANO_BIN": binary.path]

        #expect(LaunchDispatch.runsOwningApp(
            executablePath: bin.appendingPathComponent("soprano").path, environment: pane
        ))
        #expect(!LaunchDispatch.runsOwningApp(executablePath: "/tmp/elsewhere/.build/debug/Soprano", environment: pane))
        // Without a recorded binary, a call from a pane is taken to be the owning app's.
        #expect(LaunchDispatch.runsOwningApp(executablePath: "/tmp/x/Soprano", environment: paneEnvironment))
    }
}
