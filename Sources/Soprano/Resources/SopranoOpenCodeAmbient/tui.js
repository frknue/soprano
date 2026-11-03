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
    // Packaged apps keep the bundle in Resources; `swift build` puts it beside the binary.
    const plugin = [
      join(dirname(binary), "../Resources/Soprano_Soprano.bundle/SopranoOpenCode/tui.js"),
      join(dirname(binary), "Soprano_Soprano.bundle/SopranoOpenCode/tui.js"),
    ].find((path) => existsSync(path))
    if (!plugin) return
    const { register } = await import(pathToFileURL(plugin).href)
    return register(context)
  },
}
