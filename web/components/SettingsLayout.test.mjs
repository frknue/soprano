import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
const settingsConfigSource = await readFile(new URL("./SettingsConfig.tsx", import.meta.url), "utf8");

function ruleBody(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
}

test("settings panels retain natural height inside the scrollable content area", () => {
  assert.match(ruleBody(".settings-content"), /overflow-y:\s*auto/);
  assert.match(ruleBody(".settings-panel-inner"), /flex-shrink:\s*0/);
});

// Regression cover for issue #56 ("Extensions & Tools" cannot be scrolled): in the
// released 0.4.x layout the MCP tabpanel was itself the height-bounded scroller
// (`height: 100%` + `min-height: 0` + `overflow-y: auto`) nested inside
// `.settings-content`. Because it was a column flex container, its section children
// shrank to fit instead of overflowing, so panel.scrollHeight === panel.clientHeight and
// neither the panel nor `.settings-content` had anything to scroll. Exactly one element
// in the chain may own the scroll, and panels must stay unbounded.
test("only .settings-content owns the settings scroll", () => {
  const content = ruleBody(".settings-content");
  assert.match(content, /overflow-y:\s*auto/, ".settings-content must stay the scroller");
  assert.match(content, /flex:\s*1/, ".settings-content must grow inside .settings-body");
  assert.match(content, /min-height:\s*0/, ".settings-content must be shrinkable, not auto-minimum sized");

  const body = ruleBody(".settings-body");
  assert.match(body, /overflow:\s*hidden/, ".settings-body must clip instead of growing");
  assert.match(body, /min-height:\s*0/);
  assert.match(body, /flex:\s*1/);

  const panel = ruleBody(".settings-panel-inner");
  assert.match(panel, /flex-shrink:\s*0/, "panels must keep their natural height");
  assert.doesNotMatch(panel, /(^|[;\s])height\s*:/, ".settings-panel-inner must not declare a height");
  assert.doesNotMatch(panel, /overflow/, "panels must not clip their own content");
});

test("no settings tabpanel binds itself to the content height", () => {
  const panels = settingsConfigSource.match(/role="tabpanel"[\s\S]*?>/g) ?? [];
  assert.ok(panels.length >= 9, `expected the settings tabpanels, found ${panels.length}`);
  for (const panel of panels) {
    assert.doesNotMatch(panel, /(^|[^-\w])height\s*:\s*"/, `tabpanel must not set an explicit height: ${panel}`);
    assert.doesNotMatch(panel, /overflow/, `tabpanel must not own scrolling: ${panel}`);
  }
  // .settings-panel-inner is what makes the panels grow to their content height.
  assert.match(settingsConfigSource, /className="settings-panel-inner"/);
});
