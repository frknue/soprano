import AppKit

@MainActor
enum SystemSetup {
    private struct Setting {
        let domain: String
        let key: String
        let type: String
        let value: String
    }

    private static let settings: [Setting] = [
        Setting(domain: "NSGlobalDomain", key: "AppleInterfaceStyle", type: "string", value: "Dark"),
        Setting(domain: "NSGlobalDomain", key: "AppleAccentColor", type: "int", value: "1"),
        Setting(domain: "NSGlobalDomain", key: "AppleHighlightColor", type: "string", value: "1.000000 0.419608 0.101961 Other"),
        Setting(domain: "NSGlobalDomain", key: "_HIHideMenuBar", type: "bool", value: "true"),
        Setting(domain: "com.apple.dock", key: "autohide", type: "bool", value: "true"),
        Setting(domain: "com.apple.dock", key: "autohide-delay", type: "float", value: "0"),
        Setting(domain: "com.apple.dock", key: "autohide-time-modifier", type: "float", value: "0.18"),
        Setting(domain: "com.apple.dock", key: "mineffect", type: "string", value: "scale"),
        Setting(domain: "com.apple.dock", key: "launchanim", type: "bool", value: "true"),
        Setting(domain: "com.apple.dock", key: "show-recents", type: "bool", value: "false"),
        Setting(domain: "com.apple.dock", key: "expose-group-apps", type: "bool", value: "true"),
        Setting(domain: "com.apple.dock", key: "mru-spaces", type: "bool", value: "false"),
        Setting(domain: "com.apple.finder", key: "ShowPathbar", type: "bool", value: "true"),
        Setting(domain: "com.apple.finder", key: "ShowStatusBar", type: "bool", value: "true"),
        Setting(domain: "com.apple.universalaccess", key: "reduceMotion", type: "bool", value: "false")
    ]

    static let backupURL = Desktop.support.appendingPathComponent("original-settings.plist")

    static func apply() throws -> [String] {
        try saveOriginals()
        var failures: [String] = []
        var dockChanged = false
        for setting in settings {
            let current = UserDefaults.standard.persistentDomain(forName: setting.domain)?[setting.key]
            let matches = switch setting.type {
            case "bool": (current as? Bool) == (setting.value == "true")
            case "int", "float": (current as? NSNumber)?.doubleValue == Double(setting.value)
            default: (current as? String) == setting.value
            }
            if matches { continue }
            do {
                try Desktop.run("/usr/bin/defaults", ["write", setting.domain, setting.key, "-\(setting.type)", setting.value])
                if setting.domain == "com.apple.dock" { dockChanged = true }
            }
            catch { failures.append("\(setting.domain).\(setting.key): \(error.localizedDescription)") }
        }
        for screen in NSScreen.screens {
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            let url = Desktop.support.appendingPathComponent("assets/wallpaper-\(width)x\(height).png")
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                    options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
            } catch { failures.append("wallpaper: \(error.localizedDescription)") }
        }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("AppleColorPreferencesChangedNotification"), object: nil)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.apple.accessibility.api"), object: nil)
        if dockChanged { try Desktop.run("/usr/bin/killall", ["Dock"]) }
        // Finder refreshes its view options without terminating existing windows.
        return failures
    }

    private static func saveOriginals() throws {
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        var originals: [[String: Any]] = []
        for setting in settings {
            let domain = UserDefaults.standard.persistentDomain(forName: setting.domain) ?? [:]
            var record: [String: Any] = ["domain": setting.domain, "key": setting.key, "exists": domain[setting.key] != nil]
            if let value = domain[setting.key] { record["value"] = value }
            originals.append(record)
        }
        let wallpapers = NSScreen.screens.enumerated().compactMap { index, screen -> [String: Any]? in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return ["display": displayID(screen), "index": index, "url": url.absoluteString]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["settings": originals, "wallpapers": wallpapers], format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Desktop.support, withIntermediateDirectories: true)
        try data.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    static func restore() throws -> [String] {
        let data = try Data(contentsOf: backupURL)
        guard let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let originals = backup["settings"] as? [[String: Any]],
              let wallpapers = backup["wallpapers"] as? [[String: Any]] else {
            throw DesktopError.message("The original settings backup is invalid; nothing has been restored")
        }
        var failures: [String] = []
        for record in originals {
            guard let domain = record["domain"] as? String, let key = record["key"] as? String,
                  let existed = record["exists"] as? Bool else { throw DesktopError.message("Invalid preference backup record") }
            do {
                if existed, let value = record["value"] {
                    let current = UserDefaults.standard.persistentDomain(forName: domain)?[key]
                    if let current = current as? NSObject, let value = value as? NSObject, current.isEqual(value) { continue }
                    let type: String
                    let text: String
                    if let string = value as? String {
                        type = "string"
                        text = string
                    } else if let number = value as? NSNumber {
                        let encoding = String(cString: number.objCType)
                        type = CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool"
                            : (encoding == "d" || encoding == "f" ? "float" : "int")
                        text = number.stringValue
                    } else {
                        throw DesktopError.message("Unsupported original preference type for \(domain).\(key)")
                    }
                    try Desktop.run("/usr/bin/defaults", ["write", domain, key, "-\(type)", text])
                } else {
                    let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
                    if current[key] != nil { try Desktop.run("/usr/bin/defaults", ["delete", domain, key]) }
                }
            } catch { failures.append("\(domain).\(key): \(error.localizedDescription)") }
        }
        for screen in NSScreen.screens {
            let record = wallpapers.first { ($0["display"] as? UInt32) == displayID(screen) }
            guard let value = record?["url"] as? String, let url = URL(string: value) else { continue }
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]) }
            catch { failures.append("wallpaper: \(error.localizedDescription)") }
        }
        try Desktop.run("/usr/bin/killall", ["Dock"])
        return failures
    }

    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
