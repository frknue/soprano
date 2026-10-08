import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

test("ui scale zoom keeps the html box at 100% so the viewport stays filled", async () => {
  const source = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  const box = String.raw`calc\(100%\s*\/\s*var\(--ui-scale\)\)`;

  // Blink, WebKit, and Gecko all resolve the root element's percentage box
  // against a zoom-adjusted initial containing block, so html/body at 100%
  // already paint to the exact window at any zoom. Dividing the box by
  // --ui-scale double-compensates: zoom > 1 letterboxes (empty gap at the
  // right/bottom edges) and zoom < 1 clips. These assertions keep that
  // division from coming back.
  for (const name of ["compact", "standard", "comfortable", "large"]) {
    const block = source.match(new RegExp(`html\\[data-ui-scale="${name}"\\]\\s*\\{[^}]*\\}`));
    assert.ok(block, `missing html[data-ui-scale="${name}"]`);
    assert.match(block[0], /zoom:\s*[\d.]+;/);
    assert.doesNotMatch(block[0], new RegExp(`(max-)?(width|height):\\s*${box}`));
  }

  // The unlayered html, body rule below sizes the box; no grouped rule may
  // override it with a divided box.
  assert.doesNotMatch(
    source,
    new RegExp(`html\\[data-ui-scale="compact"\\],[^{}]*\\{[^}]*height:\\s*${box}`),
  );
  assert.match(source, /html, body \{[^}]*height:\s*100%;/);
});

test("settings dialogs still divide viewport units by --ui-scale", async () => {
  // Viewport units are zoom-invariant: 78vh paints 78% * scale tall. Dialogs
  // must keep dividing their vh/dvh sizes by --ui-scale to fit the window.
  const files = [
    "ModelCatalogPicker.tsx",
    "ModelsConfig-panels.tsx",
    "PluginsConfig.tsx",
    "SkillsConfig.tsx",
  ];
  for (const file of files) {
    const source = await readFile(new URL(`./${file}`, import.meta.url), "utf8");
    assert.match(
      source,
      /dvh\s*\/\s*var\(--ui-scale\)|vh\s*\/\s*var\(--ui-scale\)/,
      `${file} must divide viewport units by var(--ui-scale)`,
    );
  }
});

test("upstream's coarse-pointer 44px targets apply only in the Accessible mode", async () => {
  const source = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  // Narrow-viewport and touch-sidebar layout blocks size rows for the layout, not
  // per control; Compact overrides those explicitly. Only top-level rules and
  // upstream's per-control `@media (pointer: coarse)` blocks belong behind the mode.
  const ungated = [];
  for (const match of source.matchAll(/min-(?:height|width):\s*44px/g)) {
    const open = source.lastIndexOf("{", match.index);
    const selector = source.slice(source.lastIndexOf("}", open) + 1, open).trim();
    if (selector.includes('html[data-touch-targets="accessible"]')) continue;
    let depth = 0;
    let context = "";
    for (let i = open - 1; i >= 0; i--) {
      if (source[i] === "}") depth++;
      else if (source[i] === "{" && depth-- === 0) {
        context = source.slice(source.lastIndexOf("}", i) + 1, i).trim();
        break;
      }
    }
    if (context === "" || /^@media\s*\(pointer:\s*coarse\)$/.test(context)) ungated.push(selector);
  }
  assert.deepEqual(ungated, [], "44px rules outside the Accessible mode override Compact and Auto");
});

test("touch targets density options define accessible and compact modes with inline source tag", async () => {
  const source = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.match(source, /@source\s+inline\("data-touch-targets"\);/);
  assert.match(source, /html\[data-touch-targets="compact"\]\s+\.composer-primary-action\s*\{[^}]*min-height:\s*28px/);
  assert.match(source, /html\[data-touch-targets="compact"\]\s+\.session-item-row\s*\{[^}]*min-height:\s*30px/);
  assert.match(source, /html\[data-touch-targets="compact"\]\s+\.settings-card\s*\{[^}]*padding:\s*10px 16px/);
});
