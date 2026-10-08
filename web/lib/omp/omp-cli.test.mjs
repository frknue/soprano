import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { mkdtempSync, readFileSync, renameSync, rmSync, statSync, symlinkSync, mkdirSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createJiti } from "jiti";

function setup(t, execute) {
  const dir = mkdtempSync(join(tmpdir(), "omp-version-"));
  const bin = join(dir, "omp");
  writeFileSync(bin, "omp/18.1.19\n");
  const previousBin = process.env.OMP_WEB_OMP_BIN;
  process.env.OMP_WEB_OMP_BIN = bin;
  t.after(() => {
    if (previousBin === undefined) delete process.env.OMP_WEB_OMP_BIN;
    else process.env.OMP_WEB_OMP_BIN = previousBin;
    rmSync(dir, { recursive: true, force: true });
  });
  t.mock.method(childProcess, "execFile", (path, _args, _options, callback) => {
    if (execute) execute(callback);
    else callback(null, readFileSync(path, "utf8"));
  });
  // Keep builtin mocks on the same CJS path across supported Node versions.
  const jiti = createJiti(import.meta.url, { moduleCache: false, tryNative: false });
  return { dir, bin, getOmpVersion: jiti("./omp-cli.ts").getOmpVersion };
}

test("unchanged executables reuse the version without launching another process", async (t) => {
  let launches = 0;
  const { bin, getOmpVersion } = setup(t, (callback) => {
    launches++;
    callback(null, readFileSync(bin, "utf8"));
  });
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  assert.equal(launches, 1);
  writeFileSync(bin, "omp/18.1.210\n");
  assert.equal(await getOmpVersion(), "omp/18.1.210");
  assert.equal(launches, 2);
});

test("atomic replacement invalidates even with the same size and modification time", async (t) => {
  const { dir, bin, getOmpVersion } = setup(t);
  const original = statSync(bin);
  // Normalize both mtimes to the same precision before taking the cache snapshot.
  utimesSync(bin, original.atime, original.mtime);
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  const replacement = join(dir, "replacement");
  writeFileSync(replacement, "omp/18.1.21\n");
  utimesSync(replacement, original.atime, original.mtime);
  assert.equal(statSync(replacement, { bigint: true }).mtimeNs, statSync(bin, { bigint: true }).mtimeNs);
  renameSync(replacement, bin);
  assert.equal(await getOmpVersion(), "omp/18.1.21");
});

test("retargeting the release directory invalidates the cached version", async (t) => {
  const { dir, bin, getOmpVersion } = setup(t);
  const first = join(dir, "first");
  const second = join(dir, "second");
  mkdirSync(first);
  mkdirSync(second);
  renameSync(bin, join(first, "omp"));
  writeFileSync(join(second, "omp"), "omp/18.1.21\n");
  const current = join(dir, "current");
  symlinkSync(first, current, "junction");
  process.env.OMP_WEB_OMP_BIN = join(current, "omp");
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  unlinkSync(current);
  symlinkSync(second, current, "junction");
  assert.equal(await getOmpVersion(), "omp/18.1.21");
});

test("unchanged launchers are re-probed after the five-minute safety expiry", async (t) => {
  let now = Date.now();
  t.mock.method(Date, "now", () => now);
  let installedVersion = "omp/18.1.19\n";
  const { getOmpVersion } = setup(t, (callback) => callback(null, installedVersion));
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  installedVersion = "omp/18.1.21\n";
  now += 5 * 60_000 - 1;
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  now++;
  assert.equal(await getOmpVersion(), "omp/18.1.21");
});

test("overlapping version lookups share a result instead of racing failure backoff", async (t) => {
  const callbacks = [];
  const { bin, getOmpVersion } = setup(t, (callback) => callbacks.push(callback));
  const first = getOmpVersion();
  const second = getOmpVersion();
  if (callbacks.length > 1) {
    callbacks[1](null, "omp/18.1.19\n");
    await second;
    callbacks[0](new Error("executable replaced during update"), "");
  } else {
    callbacks[0](null, "omp/18.1.19\n");
  }
  assert.deepEqual(await Promise.all([first, second]), ["omp/18.1.19", "omp/18.1.19"]);
  writeFileSync(bin, "omp/18.1.210\n");
  const refreshed = getOmpVersion();
  callbacks.at(-1)(null, "omp/18.1.210\n");
  assert.equal(await refreshed, "omp/18.1.210");
});

test("an update during a probe does not cache its old result", async (t) => {
  const callbacks = [];
  const { bin, getOmpVersion } = setup(t, (callback) => callbacks.push(callback));
  const first = getOmpVersion();
  writeFileSync(bin, "omp/18.1.210\n");
  callbacks[0](null, "omp/18.1.19\n");
  assert.equal(await first, "omp/18.1.19");
  const refreshed = getOmpVersion();
  callbacks.at(-1)(null, "omp/18.1.210\n");
  assert.equal(await refreshed, "omp/18.1.210");
});

test("changed executables recover immediately from a failed-probe backoff", async (t) => {
  let fail = true;
  const { bin, getOmpVersion } = setup(t, (callback) => {
    callback(fail ? new Error("update in progress") : null, "omp/18.1.21\n");
  });
  assert.equal(await getOmpVersion(), null);
  fail = false;
  writeFileSync(bin, "updated executable\n");
  assert.equal(await getOmpVersion(), "omp/18.1.21");
});

test("removing an executable never serves its cached version", async (t) => {
  const { bin, getOmpVersion } = setup(t);
  assert.equal(await getOmpVersion(), "omp/18.1.19");
  rmSync(bin);
  assert.equal(await getOmpVersion(), null);
});
