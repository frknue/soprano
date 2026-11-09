// Install in omp's extensions directory to recognize `omp` started in a Soprano shell.
// The built-in launcher loads the companion extension explicitly; do not double-report.
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"

export default async function (omp) {
  const binary = process.env.SOPRANO_BIN
  if (!binary || process.env.SOPRANO_AGENT_PROFILE) return

  // Where each package keeps the bundle, relative to the binary (the same search as
  // soprano_platform::paths::resources_dir): the macOS app's Resources, a Linux prefix's
  // share/soprano, a Windows or portable folder's resources, and a source checkout.
  const extensionPath = [
    "../Resources",
    "../share/soprano",
    "resources",
    "../../resources",
  ]
    .map((root) => join(dirname(binary), root, "Soprano_Soprano.bundle/SopranoOmpExtension.js"))
    .find((path) => existsSync(path))
  if (!extensionPath) return
  const { default: register } = await import(pathToFileURL(extensionPath).href)
  register(omp)
}
