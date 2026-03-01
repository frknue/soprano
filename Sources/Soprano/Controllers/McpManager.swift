import Foundation

/// Manages MCP server processes — start, stop, restart, health monitoring.
final class McpManager: @unchecked Sendable {
    private(set) var configs: [McpServerConfig] = []
    private(set) var instances: [String: McpServerInstance] = [:]
    private var processes: [String: Process] = [:]
    private var observers: [String: () -> Void] = [:]
    private var healthTimer: Timer?

    var pool: [McpPoolEntry] {
        configs.map { config in
            McpPoolEntry(
                config: config,
                instance: instances[config.id] ?? McpServerInstance(id: config.id)
            )
        }
    }

    var runningCount: Int {
        instances.values.filter { $0.status == .running }.count
    }

    init() {
        configs = DefaultMcpServers.load()
        for config in configs {
            instances[config.id] = McpServerInstance(id: config.id)
        }
        startHealthMonitor()
    }

    deinit {
        healthTimer?.invalidate()
        stopAll()
    }

    // MARK: - Server Lifecycle

    func startServer(_ id: String) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        guard instances[id]?.status != .running,
              instances[id]?.status != .starting
        else { return }

        let instance = instances[id] ?? McpServerInstance(id: id)
        instance.status = .starting
        instance.error = nil
        instances[id] = instance
        notifyChange()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args

        var env = ProcessInfo.processInfo.environment
        if let configEnv = config.env {
            for (key, value) in configEnv {
                env[key] = value
            }
        }
        process.environment = env

        // Prevent stdout/stderr from blocking
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleProcessExit(id: id, exitCode: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            instance.status = .running
            instance.pid = process.processIdentifier
            instance.url = "http://localhost:\(config.port)/sse"
            instance.startedAt = Date()
            instance.error = nil
            processes[id] = process
            notifyChange()
        } catch {
            instance.status = .error
            instance.error = error.localizedDescription
            notifyChange()
        }
    }

    func stopServer(_ id: String) {
        guard let process = processes[id] else {
            instances[id]?.status = .stopped
            instances[id]?.pid = nil
            instances[id]?.url = nil
            instances[id]?.error = nil
            notifyChange()
            return
        }

        process.terminate()

        // Give it a moment, then force if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if process.isRunning {
                process.interrupt()
            }
            self?.processes.removeValue(forKey: id)
        }

        let instance = instances[id] ?? McpServerInstance(id: id)
        instance.status = .stopped
        instance.pid = nil
        instance.url = nil
        instance.startedAt = nil
        instance.error = nil
        instances[id] = instance
        processes.removeValue(forKey: id)
        notifyChange()
    }

    func restartServer(_ id: String) {
        stopServer(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startServer(id)
        }
    }

    func stopAll() {
        for id in processes.keys {
            stopServer(id)
        }
    }

    func autoStartServers() {
        for config in configs where config.autoStart {
            if instances[config.id]?.status == .stopped {
                startServer(config.id)
            }
        }
    }

    // MARK: - Config Management

    func addServer(_ config: McpServerConfig) {
        configs.append(config)
        instances[config.id] = McpServerInstance(id: config.id)
        persistConfigs()
        notifyChange()
    }

    func removeServer(_ id: String) {
        if instances[id]?.status == .running {
            stopServer(id)
        }
        configs.removeAll { $0.id == id }
        instances.removeValue(forKey: id)
        processes.removeValue(forKey: id)
        persistConfigs()
        notifyChange()
    }

    func updateServer(
        _ id: String,
        name: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        port: UInt16? = nil,
        autoStart: Bool? = nil
    ) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        if let name { configs[index].name = name }
        if let command { configs[index].command = command }
        if let args { configs[index].args = args }
        if let env { configs[index].env = env }
        if let port { configs[index].port = port }
        if let autoStart { configs[index].autoStart = autoStart }
        persistConfigs()
        notifyChange()
    }

    // MARK: - Observer Pattern

    func addObserver(id: String, handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    // MARK: - Private

    private func notifyChange() {
        for (_, handler) in observers {
            handler()
        }
    }

    private func persistConfigs() {
        DefaultMcpServers.save(configs)
    }

    private func handleProcessExit(id: String, exitCode: Int32) {
        guard let instance = instances[id], instance.status == .running else { return }
        instance.status = .error
        instance.error = "Process exited (code: \(exitCode))"
        instance.pid = nil
        instance.url = nil
        processes.removeValue(forKey: id)
        notifyChange()
    }

    private func startHealthMonitor() {
        healthTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        for (id, instance) in instances where instance.status == .running {
            if processes[id] == nil || processes[id]?.isRunning != true {
                instance.status = .error
                instance.error = "Process not found"
                instance.pid = nil
                instance.url = nil
                processes.removeValue(forKey: id)
                notifyChange()
            }
        }
    }
}
