import AppKit
import IOKit.ps

struct SystemMetrics {
    let battery: String
    let memory: String
    let uptime: String
    let appCount: Int
    let load: String

    @MainActor
    static func read() -> SystemMetrics {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        let resident = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
        let memory = result == KERN_SUCCESS && pageResult == KERN_SUCCESS && total > 0
            ? String(format: "%.1f / %.0f GB", Double(resident) / 1_073_741_824, Double(total) / 1_073_741_824)
            : "unavailable"
        var loads = [Double](repeating: 0, count: 3)
        let load = getloadavg(&loads, 3) == 3 ? String(format: "%.2f", loads[0]) : "unavailable"
        let minutes = Int(ProcessInfo.processInfo.systemUptime / 60)
        let uptime = "\(minutes / 60)h \(minutes % 60)m"
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
        return SystemMetrics(battery: batteryStatus(), memory: memory, uptime: uptime, appCount: apps, load: load)
    }

    private static func batteryStatus() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "AC" }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return "\(current * 100 / maximum)%\(pluggedIn ? " +" : "")"
        }
        return "AC"
    }
}
