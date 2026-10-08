import assert from "node:assert/strict";
import test from "node:test";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url, { tsconfigPaths: true });
const { isMessageOverflowing } = await jiti.import("./message-overflow.ts");

test("does not mark a message as overflowing at the capped height", () => {
  assert.equal(isMessageOverflowing({ scrollHeight: 300, clientHeight: 300 }), false);
  assert.equal(isMessageOverflowing({ scrollHeight: 301, clientHeight: 300 }), false);
});

test("marks content beyond the cap as overflowing", () => {
  assert.equal(isMessageOverflowing({ scrollHeight: 302, clientHeight: 300 }), true);
  assert.equal(isMessageOverflowing({ scrollHeight: 900, clientHeight: 300 }), true);
});
