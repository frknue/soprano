import assert from "node:assert/strict";
import test from "node:test";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url);
const { checkNpmUpdate, detectInstallMethod } = jiti("./npm-update.ts");

test("application updates are managed by Soprano", async () => {
  const status = await checkNpmUpdate();
  assert.equal(status.updatesDisabled, true);
  assert.equal(status.updateAvailable, false);
  assert.equal(status.availableVersion, null);
  assert.equal(status.updateCommand, "Update Soprano");
});

test("detectInstallMethod routes bun-global installs to bun", () => {
  process.env.USERPROFILE = "C:\\Users\\khaled";
  assert.equal(detectInstallMethod("C:\\Users\\khaled\\node_modules\\@kahme247\\ompweb"), "bun");
  assert.equal(detectInstallMethod("C:\\Users\\khaled\\node_modules\\.bin\\omp-web.cmd"), "bun");
  // Mixed separators (Windows-style path on a POSIX host, e.g. CI) must classify identically.
  assert.equal(detectInstallMethod("C:/Users/khaled/node_modules/@kahme247/ompweb"), "bun");
});

test("detectInstallMethod falls back to npm for anything else", () => {
  process.env.USERPROFILE = "C:\\Users\\khaled";
  assert.equal(detectInstallMethod("C:\\Users\\khaled\\AppData\\Roaming\\npm\\node_modules\\@kahme247\\ompweb"), "npm");
  assert.equal(detectInstallMethod("C:\\Program Files\\nodejs\\node_modules\\@kahme247\\ompweb"), "npm");
  assert.equal(detectInstallMethod("D:\\OtherProjects\\omp-web"), "npm");
});
