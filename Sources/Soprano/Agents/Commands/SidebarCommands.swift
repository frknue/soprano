import AppKit
import SopranoAgentsCore

/// Sidebar module: new thread, thread navigation (⇧⌘[ ⇧⌘] ⌘1–9), settle, pin, rename, archive, delete, add project.
@MainActor
enum SidebarCommands {
    static var all: [AppCommand] { [] }
}
