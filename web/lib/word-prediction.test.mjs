import assert from "node:assert/strict";
import test from "node:test";

async function loadSubject() {
  return import("./word-prediction.ts");
}

const ghost = { text: "Check the weath\nnext", cursor: 15, suffix: "er" };

test("typing that matches the ghost keeps its remainder", async () => {
  const { advanceGhost } = await loadSubject();
  assert.deepEqual(advanceGhost(ghost, "Check the weathe\nnext", 16), {
    ghost: { text: "Check the weathe\nnext", cursor: 16, suffix: "r" },
    typedPast: false,
  });
  // Case-insensitive, like omp's projection.
  assert.equal(advanceGhost(ghost, "Check the weathE\nnext", 16).ghost?.suffix, "r");
});

test("typing the whole suggestion retires the ghost without a rejection", async () => {
  const { advanceGhost } = await loadSubject();
  assert.deepEqual(advanceGhost(ghost, "Check the weather\nnext", 17), { ghost: null, typedPast: false });
});

test("typing past the ghost reports a rejection; other edits just drop it", async () => {
  const { advanceGhost } = await loadSubject();
  assert.deepEqual(advanceGhost(ghost, "Check the weathx\nnext", 16), { ghost: null, typedPast: true });
  assert.deepEqual(advanceGhost(ghost, "Check the weat\nnext", 14), { ghost: null, typedPast: false });
  assert.deepEqual(advanceGhost(ghost, ghost.text, 3), { ghost: null, typedPast: false });
  assert.deepEqual(advanceGhost(ghost, "Check the weathe\nnexts", 16), { ghost: null, typedPast: false });
});

test("accepting adds omp's trailing space unless whitespace or punctuation follows", async () => {
  const { acceptGhost } = await loadSubject();
  assert.deepEqual(acceptGhost({ text: "the weath", cursor: 9, suffix: "er" }), { text: "the weather ", cursor: 12 });
  assert.deepEqual(acceptGhost(ghost), { text: "Check the weather\nnext", cursor: 17 });
  assert.deepEqual(acceptGhost({ text: "the weath.", cursor: 9, suffix: "er" }), { text: "the weather.", cursor: 11 });
});

test("ghost text only paints at the end of a line", async () => {
  const { atLineEnd } = await loadSubject();
  assert.equal(atLineEnd("abc", 3), true);
  assert.equal(atLineEnd("abc\ndef", 3), true);
  assert.equal(atLineEnd("abc def", 3), false);
});
