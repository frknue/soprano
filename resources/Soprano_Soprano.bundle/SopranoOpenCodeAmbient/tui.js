// Link this directory into OpenCode 2's plugin directory to recognize `opencode`
// started in a Soprano shell. The built-in launcher loads SopranoOpenCode
// explicitly; do not double-report.
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"

export default {
  id: "soprano.shell",
  async setup(context) {
    const binary = process.env.SOPRANO_BIN
    if (!binary || process.env.SOPRANO_AGENT_PROFILE) return
    // Where each package keeps the bundle, relative to the binary (the same search as
    // soprano_platform::paths::resources_dir): the macOS app's Resources, a Linux prefix's
    // share/soprano, a Windows or portable folder's resources, and a source checkout.
    const plugin = [
      "../Resources",
      "../share/soprano",
      "resources",
      "../../resources",
    ]
      .map((root) => join(dirname(binary), root, "Soprano_Soprano.bundle/SopranoOpenCode/tui.js"))
      .find((path) => existsSync(path))
    if (!plugin) return
    const { register } = await import(pathToFileURL(plugin).href)
    return register(context)
  },
}
