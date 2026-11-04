// Install in omp's extensions directory to recognize `omp` started in a Soprano shell.
// The built-in launcher loads the companion extension explicitly; do not double-report.
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"

export default async function (omp) {
  const binary = process.env.SOPRANO_BIN
  if (!binary || process.env.SOPRANO_AGENT_PROFILE) return

  // Packaged apps keep the bundle in Resources; `swift build` puts it beside the binary.
  const extensionPath = [
    join(dirname(binary), "../Resources/Soprano_Soprano.bundle/SopranoOmpExtension.js"),
    join(dirname(binary), "Soprano_Soprano.bundle/SopranoOmpExtension.js"),
  ].find((path) => existsSync(path))
  if (!extensionPath) return
  const { default: register } = await import(pathToFileURL(extensionPath).href)
  register(omp)
}
