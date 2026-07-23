import Testing
import AppKit
@testable import Soprano

struct PackagedResourceLookupTests {
    @Test func openCodePluginResolvesInsideThePackagedSwiftPMResourceBundle() {
        let resourcesURL = URL(
            fileURLWithPath: "/Applications/Soprano.app/Contents/Resources",
            isDirectory: true
        )

        let pluginURL = PackagedResourceLocator.openCodePluginURL(
            resourcesURL: resourcesURL,
            fileExists: { _ in true }
        )

        #expect(pluginURL?.path == "/Applications/Soprano.app/Contents/Resources/Soprano_Soprano.bundle/SopranoOpenCodePlugin.js")
    }

    @Test func openCodePluginIsUnavailableWithoutAppResources() {
        #expect(PackagedResourceLocator.openCodePluginURL(resourcesURL: nil) == nil)
    }
}
