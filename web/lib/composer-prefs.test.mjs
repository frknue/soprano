import assert from "node:assert/strict";
import test, { afterEach } from "node:test";

async function loadSubject() {
  return import("./composer-prefs.ts");
}

function fakeWindow({ finePointer, stored }) {
  const store = new Map(stored === undefined ? [] : [["omp-web:word-completion", stored]]);
  globalThis.window = {
    localStorage: { getItem: (key) => store.get(key) ?? null, setItem: (key, value) => store.set(key, value) },
    matchMedia: (query) => ({ matches: query === "(pointer: fine)" && finePointer }),
  };
}

afterEach(() => {
  delete globalThis.window;
});

test("word completion defaults to auto: on with a mouse/trackpad, off on touch", async () => {
  const { getWordCompletionMode, isWordCompletionEnabled } = await loadSubject();
  fakeWindow({ finePointer: true });
  assert.equal(getWordCompletionMode(), "auto");
  assert.equal(isWordCompletionEnabled(), true);
  fakeWindow({ finePointer: false });
  assert.equal(isWordCompletionEnabled(), false);
});

test("Enabled and Disabled override the pointer heuristic; junk falls back to auto", async () => {
  const { isWordCompletionEnabled, setWordCompletionMode, getWordCompletionMode } = await loadSubject();
  fakeWindow({ finePointer: false, stored: "on" });
  assert.equal(isWordCompletionEnabled(), true);
  setWordCompletionMode("off");
  fakeWindow({ finePointer: true, stored: "off" });
  assert.equal(isWordCompletionEnabled(), false);
  fakeWindow({ finePointer: true, stored: "sometimes" });
  assert.equal(getWordCompletionMode(), "auto");
});
