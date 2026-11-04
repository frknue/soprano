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

    @Test func anyUnclaimedInvocationInsideASopranoTerminalNeverStartsTheApp() {
        #expect(LaunchDispatch.decide(arguments: ["soprano"], environment: paneEnvironment) == .usageError)
        #expect(LaunchDispatch.decide(
            arguments: ["soprano", "-NSDocumentRevisionsDebugMode", "YES"],
            environment: paneEnvironment
        ) == .usageError)
        #expect(LaunchDispatch.decide(arguments: ["soprano"], environment: ["SOPRANO_APP_PID": ""]) == .startApp)
    }
}
