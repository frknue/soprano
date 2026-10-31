import Foundation

/// Extra environment and arguments for one omp spawn, such as the accounts the app picked
/// (`--config <overlay>`). Drivers and sessions read
/// it through a `@Sendable () -> ProviderLaunchAdjustments` closure on every spawn (sessions,
/// probes, text generation), the same way they read `executablePath`; the app injects it
/// from `EngineFactory`, tests and fixtures use `.none`.
public struct ProviderLaunchAdjustments: Sendable, Hashable {
    /// Set on the child after the app's own variables, so these win.
    public var environment: [String: String]
    /// Put before the provider's own arguments.
    public var arguments: [String]

    public init(environment: [String: String] = [:], arguments: [String] = []) {
        self.environment = environment
        self.arguments = arguments
    }

    public static let none = ProviderLaunchAdjustments()

    /// `overrides` with this spawn's environment on top.
    public func environment(over overrides: [String: String]) -> [String: String] {
        overrides.merging(environment) { _, adjusted in adjusted }
    }

    /// This spawn's arguments, then the provider's.
    public func arguments(before providerArguments: [String]) -> [String] {
        arguments + providerArguments
    }
}
