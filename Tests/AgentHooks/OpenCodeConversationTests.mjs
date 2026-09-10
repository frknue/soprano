// Run with node --test Tests/AgentHooks/OpenCodeConversationTests.mjs.
// The plugin runs against a fake SDK and subprocess bridge; no agent is started.
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const source = await readFile(new URL("../../Sources/Soprano/Resources/SopranoOpenCodePlugin.js", import.meta.url), "utf8")
const { SopranoNotificationPlugin } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)

async function harness({ resume, lookup = {} } = {}) {
  const calls = []
  process.env.SOPRANO_BIN = "/test/soprano"
  if (resume) process.env.SOPRANO_RESUME_SESSION_ID = resume
  else delete process.env.SOPRANO_RESUME_SESSION_ID
  globalThis.Bun = {
    spawn: (args) => {
      calls.push(args)
      return { exited: Promise.resolve(0) }
    },
  }
  const plugin = await SopranoNotificationPlugin({
    directory: "/tmp/project",
    client: { session: { get: async ({ path: { id } }) => ({ data: lookup[id] }) } },
  })
  calls.length = 0
  return {
    plugin,
    calls,
    event: (type, properties) => plugin.event({ event: { type, properties } }),
    conversations: () => calls.flatMap((args) => args.flatMap((arg, index) =>
      arg === "--message-json" ? [JSON.parse(args[index + 1])] : [],
    )).filter((payload) => payload.sessionID),
  }
}

test("new main conversations are recorded before a first reply and child activity cannot replace them", async () => {
  const h = await harness()
  await h.event("session.created", { info: { id: "ses_main", directory: "/tmp/project" } })
  await h.event("session.created", { info: { id: "ses_child", parentID: "ses_main" } })
  await h.event("session.status", { sessionID: "ses_child", status: { type: "busy" } })
  await h.event("session.idle", { sessionID: "ses_child" })
  await h.plugin["chat.message"]({ sessionID: "ses_child" })
  assert.equal(h.calls.length, 1)
  assert.deepEqual(h.conversations(), [{ sessionID: "ses_main", cwd: "/tmp/project" }])
})

test("resumed conversations are resolved through the SDK and preserve notification text", async () => {
  const h = await harness({ resume: "ses_saved", lookup: { ses_saved: { id: "ses_saved", directory: "/tmp/original" } } })
  await h.event("permission.asked", { sessionID: "ses_saved", description: "Allow the edit?" })
  assert.equal(h.calls[0][2], "needs-input")
  assert.equal(h.conversations()[0].cwd, "/tmp/original")
  assert.ok(h.calls[0].some((arg) => arg.includes("Allow the edit?")))
})

test("a prompt in another main conversation changes the saved session and ignores the previous session", async () => {
  const h = await harness({ resume: "ses_old", lookup: { ses_new: { id: "ses_new" }, ses_old: { id: "ses_old" } } })
  await h.plugin["chat.message"]({ sessionID: "ses_new" })
  await h.event("session.idle", { sessionID: "ses_old" })
  await h.event("session.updated", { info: { id: "ses_old", title: "Background title update" } })
  assert.equal(h.calls.length, 1)
  assert.equal(h.conversations()[0].sessionID, "ses_new")
})

test("child sessions discovered through the SDK cannot take over a restored pane", async () => {
  const h = await harness({ resume: "ses_main", lookup: { ses_child: { id: "ses_child", parentID: "ses_main" } } })
  await h.event("session.error", { sessionID: "ses_child" })
  await h.plugin["chat.message"]({ sessionID: "ses_child" })
  assert.equal(h.calls.length, 0)
})

test("unavailable session metadata does not interrupt the agent or invent a conversation", async () => {
  const h = await harness()
  await h.event("session.status", { sessionID: "missing", status: { type: "busy" } })
  await h.event("session.error", {})
  assert.equal(h.calls.length, 0)
})
