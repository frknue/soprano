// Run with node --test Tests/AgentHooks/OpenCodeTuiPluginTests.mjs.
// The OpenCode 2 TUI plugin runs against a fake plugin context and subprocess
// bridge; no agent is started.
import assert from "node:assert/strict"
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const pluginFile = fileURLToPath(new URL("../../Sources/Soprano/Resources/SopranoOpenCode/tui.js", import.meta.url))
const ambientFile = fileURLToPath(new URL("../../Sources/Soprano/Resources/SopranoOpenCodeAmbient/tui.js", import.meta.url))
const plugin = (await import(pluginFile)).default

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function harness({ sessions = {}, route = { type: "home" }, env = {}, setup = plugin.setup } = {}) {
  const calls = []
  const handlers = new Map()
  for (const key of ["SOPRANO_BIN", "SOPRANO_RESUME_SESSION_ID", "SOPRANO_AGENT_PROFILE", "OPENCODE_DB", "XDG_DATA_HOME"]) {
    delete process.env[key]
  }
  Object.assign(process.env, { SOPRANO_BIN: "/test/soprano", XDG_DATA_HOME: "/data" }, env)
  globalThis.Bun = {
    spawn: (args) => {
      calls.push(args)
      return { exited: Promise.resolve(0) }
    },
  }
  const state = { route }
  const memories = new Map()
  const synced = new Set()
  const context = {
    location: { directory: "/launch" },
    ui: { router: { current: () => state.route } },
    storage: {
      memory: (key, { initial }) => {
        if (!memories.has(key)) memories.set(key, structuredClone(initial))
        const store = memories.get(key)
        return [store, (mutate) => mutate(store)]
      },
    },
    data: {
      on: (type, handler) => {
        handlers.set(type, handler)
        return () => handlers.delete(type)
      },
      session: {
        get: (id) => sessions[id],
        root: (id) => (sessions[id]?.parentID ? sessions[sessions[id].parentID] && sessions[id].parentID : id),
        status: (id) => sessions[id]?.status ?? "idle",
        family: (id) => [id, ...Object.keys(sessions).filter((child) => sessions[child].parentID === id)],
        message: { list: (id) => sessions[id]?.messages ?? [] },
        // Open prompts load lazily, like the TUI's: only after a sync.
        permission: {
          list: (id) => (synced.has(`permission:${id}`) ? sessions[id]?.permissions ?? [] : undefined),
          sync: async (id) => synced.add(`permission:${id}`),
        },
        form: {
          list: (id) => (synced.has(`form:${id}`) ? sessions[id]?.forms ?? [] : undefined),
          sync: async (id) => synced.add(`form:${id}`),
        },
      },
    },
  }
  return {
    state,
    calls,
    handlers,
    start: async () => {
      state.cleanup = await setup(context)
      await flush()
    },
    emit: async (type, data) => {
      handlers.get(type)?.({ type, data })
      await flush()
    },
    states: () => calls.map((args) => args[2]),
    payloads: (index) => calls[index].flatMap((arg, at) => (arg === "--message-json" ? [JSON.parse(calls[index][at + 1])] : [])),
    flag: (index, name) => calls[index][calls[index].indexOf(name) + 1],
    stop: () => state.cleanup?.(),
  }
}

test("the conversation on screen is reported with its directory and OpenCode's database", async () => {
  const h = harness({
    sessions: { ses_main: { id: "ses_main", location: { directory: "/repo" } } },
    env: { OPENCODE_DB: "custom.db" },
  })
  await h.start()
  assert.deepEqual(h.states(), ["ready"])
  assert.deepEqual(h.payloads(0), [])

  h.state.route = { type: "session", sessionID: "ses_main" }
  await h.emit("session.execution.started", { sessionID: "ses_main" })
  assert.deepEqual(h.states(), ["ready", "ready", "running"])
  assert.deepEqual(h.payloads(1), [{ sessionID: "ses_main", cwd: "/repo", transcript_path: "/data/opencode/custom.db" }])
  assert.equal(h.payloads(2)[0].sessionID, "ses_main")
  assert.equal(h.flag(1, "--profile"), "opencode")
  h.stop()
})

test("a plugin reload keeps the turn in progress and its conversation", async () => {
  const h = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await h.start()
  await h.emit("session.execution.started", { sessionID: "ses_main" })
  h.stop()
  await h.start()
  await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
  assert.deepEqual(h.states(), ["ready", "ready", "running", "needs-input"])
  h.stop()
})

test("a finished turn asks for input once and quotes the last reply", async () => {
  const h = harness({
    route: { type: "session", sessionID: "ses_main" },
    sessions: {
      ses_main: {
        id: "ses_main",
        messages: [
          { type: "user", text: "Fix it" },
          { type: "assistant", content: [{ type: "reasoning", text: "hmm" }, { type: "text", text: "Fixed the parser." }] },
          { type: "idle" },
        ],
      },
    },
  })
  await h.start()
  await h.emit("session.execution.started", { sessionID: "ses_main" })
  await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
  await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
  assert.deepEqual(h.states(), ["ready", "ready", "running", "needs-input"])
  assert.equal(h.flag(3, "--reason"), "turn")
  assert.ok(h.calls[3].includes("--notify"))
  assert.ok(h.payloads(3).some((payload) => payload.message === "Fixed the parser."))
  h.stop()
})

test("a replayed end of turn that was never seen running stays silent", async () => {
  const h = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await h.start()
  await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
  await h.emit("session.execution.failed", { sessionID: "ses_main", error: { message: "boom" } })
  assert.deepEqual(h.states(), ["ready", "ready"])
  h.stop()
})

test("a subagent's approval request blocks the main conversation until it is answered", async () => {
  const h = harness({
    route: { type: "session", sessionID: "ses_main" },
    sessions: { ses_main: { id: "ses_main", status: "running" }, ses_child: { id: "ses_child", parentID: "ses_main", status: "running" } },
  })
  await h.start()
  await h.emit("permission.asked", { id: "per_1", sessionID: "ses_child", action: "edit", resources: ["src/app.ts"] })
  await h.emit("permission.asked", { id: "per_1", sessionID: "ses_child", action: "edit", resources: ["src/app.ts"] })
  await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
  await h.emit("permission.replied", { sessionID: "ses_child", requestID: "per_1", reply: "once" })
  assert.deepEqual(h.states(), ["ready", "running", "needs-input", "running"])
  assert.equal(h.flag(2, "--reason"), "approval")
  assert.equal(h.payloads(2).find((payload) => payload.sessionID).sessionID, "ses_main")
  assert.ok(h.payloads(2).some((payload) => payload.message === "Allow edit: src/app.ts?"))
  h.stop()
})

test("questions ask for input and failures report the error", async () => {
  const h = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await h.start()
  await h.emit("session.execution.started", { sessionID: "ses_main" })
  await h.emit("form.created", {
    form: { id: "frm_1", sessionID: "ses_main", title: "Questions", fields: [{ key: "q", type: "string", title: "Database", description: "Which database?" }] },
  })
  await h.emit("form.replied", { id: "frm_1", sessionID: "ses_main" })
  await h.emit("session.execution.failed", { sessionID: "ses_main", error: { type: "provider", message: "Rate limited" } })
  assert.deepEqual(h.states(), ["ready", "ready", "running", "needs-input", "running", "error"])
  assert.equal(h.flag(3, "--reason"), "question")
  assert.ok(h.payloads(3).some((payload) => payload.message === "Which database?"))
  assert.ok(h.payloads(5).some((payload) => payload.message === "Rate limited"))
  h.stop()
})

test("other conversations and opening a subagent never replace the pane's conversation", async () => {
  const h = harness({
    route: { type: "session", sessionID: "ses_main" },
    sessions: { ses_main: { id: "ses_main" }, ses_child: { id: "ses_child", parentID: "ses_main" }, ses_other: { id: "ses_other" } },
  })
  await h.start()
  h.state.route = { type: "session", sessionID: "ses_child" }
  await h.emit("session.execution.started", { sessionID: "ses_other" })
  await h.emit("permission.asked", { id: "per_2", sessionID: "ses_other", action: "bash" })
  assert.deepEqual(h.states(), ["ready", "ready"])

  h.state.route = { type: "session", sessionID: "ses_other" }
  await h.emit("session.execution.started", { sessionID: "ses_other" })
  assert.deepEqual(h.states(), ["ready", "ready", "ready", "running"])
  assert.equal(h.payloads(3)[0].sessionID, "ses_other")
  h.stop()
})

test("returning to a conversation that waits on a subagent's approval asks for input again", async () => {
  const h = harness({
    route: { type: "session", sessionID: "ses_main" },
    sessions: {
      ses_main: { id: "ses_main", status: "running" },
      ses_child: { id: "ses_child", parentID: "ses_main", status: "running", permissions: [{ id: "per_1", sessionID: "ses_child", action: "edit", resources: ["app.ts"] }] },
      ses_other: { id: "ses_other" },
    },
  })
  await h.start()
  assert.deepEqual(h.states(), ["ready", "running", "needs-input"])
  assert.equal(h.flag(2, "--reason"), "approval")

  h.state.route = { type: "session", sessionID: "ses_other" }
  await h.emit("session.execution.started", { sessionID: "ses_other" })
  h.state.route = { type: "session", sessionID: "ses_main" }
  await h.emit("session.execution.started", { sessionID: "ses_other" })
  assert.deepEqual(h.states().slice(3), ["ready", "running", "needs-input"])
  assert.ok(h.payloads(5).some((payload) => payload.message === "Allow edit: app.ts?"))

  await h.emit("permission.replied", { sessionID: "ses_child", requestID: "per_1", reply: "once" })
  assert.equal(h.states().at(-1), "running")
  h.stop()
})

test("another subagent waking the conversation keeps it waiting on an open approval", async () => {
  const permissions = [{ id: "per_1", sessionID: "ses_a", action: "edit", resources: ["app.ts"] }]
  const h = harness({
    route: { type: "session", sessionID: "ses_main" },
    sessions: {
      ses_main: { id: "ses_main", status: "running" },
      ses_a: { id: "ses_a", parentID: "ses_main", status: "running", permissions },
      ses_b: { id: "ses_b", parentID: "ses_main" },
    },
  })
  try {
    await h.start()
    assert.equal(h.states().at(-1), "needs-input")
    await h.emit("session.execution.started", { sessionID: "ses_main" })
    assert.equal(h.states().at(-1), "needs-input")

    permissions.length = 0
    await h.emit("permission.replied", { sessionID: "ses_a", requestID: "per_1", reply: "once" })
    assert.equal(h.states().at(-1), "running")
  } finally {
    h.stop()
  }
})

test("a conversation whose running state arrives after the TUI connected still ends with a banner", async () => {
  const sessions = { ses_main: { id: "ses_main" } }
  const h = harness({ route: { type: "session", sessionID: "ses_main" }, sessions })
  try {
    await h.start()
    assert.deepEqual(h.states(), ["ready", "ready"])
    sessions.ses_main.status = "running"
    await new Promise((resolve) => setTimeout(resolve, 700))
    assert.equal(h.states().at(-1), "running")
    sessions.ses_main.status = "idle"
    await h.emit("session.execution.succeeded", { sessionID: "ses_main" })
    assert.equal(h.states().at(-1), "needs-input")
  } finally {
    h.stop()
  }
})

test("a resumed pane keeps its conversation before the session is on screen", async () => {
  const h = harness({ env: { SOPRANO_RESUME_SESSION_ID: "ses_saved" }, sessions: { ses_saved: { id: "ses_saved" } } })
  await h.start()
  assert.equal(h.payloads(0)[0].sessionID, "ses_saved")
  h.stop()
})

test("a resumed conversation the shared server is still working on shows as working and ends with a banner", async () => {
  const h = harness({
    env: { SOPRANO_RESUME_SESSION_ID: "ses_saved" },
    route: { type: "session", sessionID: "ses_saved" },
    sessions: { ses_saved: { id: "ses_saved", status: "running" } },
  })
  await h.start()
  await h.emit("session.execution.succeeded", { sessionID: "ses_saved" })
  assert.deepEqual(h.states(), ["ready", "running", "needs-input"])
  h.stop()
})

test("an approval pending across a plugin reload returns the pane to working once answered", async () => {
  const h = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await h.start()
  await h.emit("session.execution.started", { sessionID: "ses_main" })
  await h.emit("permission.asked", { id: "per_1", sessionID: "ses_main", action: "edit" })
  h.stop()
  await h.start()
  await h.emit("permission.replied", { sessionID: "ses_main", requestID: "per_1", reply: "once" })
  assert.deepEqual(h.states(), ["ready", "ready", "running", "needs-input", "running"])
  h.stop()
})

test("a second copy of the plugin in the same terminal stays silent", async () => {
  const first = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await first.start()
  const second = harness({ route: { type: "session", sessionID: "ses_main" }, sessions: { ses_main: { id: "ses_main" } } })
  await second.start()
  await second.emit("session.execution.started", { sessionID: "ses_main" })
  assert.equal(second.calls.length, 0)
  first.stop()
})

test("outside Soprano the plugin does nothing", async () => {
  const h = harness()
  delete process.env.SOPRANO_BIN
  await h.start()
  assert.equal(h.calls.length, 0)
  assert.equal(h.handlers.size, 0)
})

test("the shell integration loads the bundled plugin but leaves launcher panes to the launcher", async () => {
  const root = await mkdtemp(join(tmpdir(), "soprano-opencode-"))
  try {
    const bundled = join(root, "Contents/Resources/Soprano_Soprano.bundle/SopranoOpenCode")
    await mkdir(bundled, { recursive: true })
    await copyFile(pluginFile, join(bundled, "tui.js"))
    const ambient = (await import(ambientFile)).default
    const binary = join(root, "Contents/MacOS/Soprano")

    const launcher = harness({ env: { SOPRANO_BIN: binary, SOPRANO_AGENT_PROFILE: "opencode" }, setup: ambient.setup })
    await launcher.start()
    assert.equal(launcher.calls.length, 0)

    const shell = harness({ env: { SOPRANO_BIN: binary }, setup: ambient.setup })
    await shell.start()
    assert.deepEqual(shell.states(), ["ready"])
    assert.notEqual(ambient.id, plugin.id)
    shell.stop()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
