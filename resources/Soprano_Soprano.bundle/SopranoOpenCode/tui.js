// OpenCode 2 terminal UI plugin. Soprano's launcher loads it through
// OPENCODE_CLI_CONFIG_CONTENT, and SopranoOpenCodeAmbient loads it for `opencode`
// typed into a Soprano shell. It runs in the pane's own TUI process, so it sees
// that pane's SOPRANO_* environment even though OpenCode 2 runs every session in
// one shared background server. OpenCode 1.x loads SopranoOpenCodePlugin.js instead.
import { homedir } from "node:os"
import { isAbsolute, join, resolve } from "node:path"

const ROUTE_POLL_MILLISECONDS = 500
const MESSAGE_LIMIT = 4096
const REGISTERED = Symbol.for("soprano.opencode.registered")

// The database OpenCode keeps sessions in, resolved like `opencode debug paths`.
// The shared server may run with another environment; Soprano checks that the
// file holds the session and searches OpenCode's data directory when it does not.
export const databasePath = (env = process.env) => {
  const configured = env.OPENCODE_DB
  if (configured === ":memory:") return undefined
  const data = join(env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "opencode")
  if (configured) return isAbsolute(configured) ? configured : resolve(data, configured)
  return join(data, "opencode.db")
}

// Reads TUI state without letting an API change upstream break the agent.
const attempt = (read, fallback) => {
  try {
    return read() ?? fallback
  } catch {
    return fallback
  }
}

const messageOption = (text) => {
  const message = typeof text === "string" ? text.trim().slice(0, MESSAGE_LIMIT) : ""
  return message ? ["--message-json", JSON.stringify({ message })] : []
}

export const register = (context) => {
  const binary = process.env.SOPRANO_BIN
  // OpenCode may probe setup without a context; a throw would show as a failed plugin.
  if (!binary || typeof context?.data?.on !== "function") return
  // The launcher's plugin stays configured in the shell a pane falls back to, where
  // the shell integration loads too; only one of them may report.
  if (globalThis[REGISTERED]) return
  globalThis[REGISTERED] = true
  const data = context.data

  // Kept across a plugin hot reload, which OpenCode performs while turns keep running.
  const [memory, update] = attempt(() => context.storage.memory("soprano", { initial: {} }), [{}, undefined])
  // The root conversation shown in this terminal. Subagent sessions report to it.
  // A resumed one is only announced: once on screen it is followed like any other,
  // which tells whether the shared server is still working on it.
  let tracked = memory.tracked
  const resumed = process.env.SOPRANO_RESUME_SESSION_ID || undefined
  // Whether the tracked conversation is mid-turn. Durable events can be replayed
  // when the TUI reconnects; only a turn seen running may end with a banner.
  let active = memory.active ?? false
  // Permission requests and forms the tracked conversation waits on.
  const waiting = new Set(memory.waiting ?? [])
  const remember = () => attempt(() => update?.((draft) => {
    draft.tracked = tracked
    draft.active = active
    draft.waiting = [...waiting]
    draft.started = true
  }), undefined)
  let queue = Promise.resolve()

  const conversation = (sessionID) => {
    const info = attempt(() => data.session.get(sessionID), undefined)
    return {
      sessionID,
      cwd: info?.location?.directory ?? info?.directory ?? context.location?.directory,
      transcript_path: databasePath(),
    }
  }

  // Events go out one at a time, in order, without holding up the TUI.
  const send = (state, sessionID, options = []) => {
    const args = [binary, "agent-event", state, "--profile", "opencode", "--pid", String(process.pid), ...options]
    if (sessionID) args.push("--message-json", JSON.stringify(conversation(sessionID)))
    queue = queue.then(async () => {
      try {
        const child = Bun.spawn(args, { env: process.env, stdin: "ignore", stdout: "ignore", stderr: "ignore" })
        await child.exited
      } catch {
        // Status reporting must never interfere with OpenCode.
      }
    })
    return queue
  }

  const rootOf = (sessionID) => attempt(() => data.session.root(sessionID), sessionID)
  const isRunning = (sessionID) => attempt(() => data.session.status(sessionID), "idle") === "running"

  const askApproval = (request) => {
    waiting.add(request.id)
    remember()
    const resources = Array.isArray(request.resources) ? request.resources.join(", ") : ""
    send("needs-input", tracked, [
      "--notify", "--title", "OpenCode", "--body", "Approval required", "--reason", "approval",
      ...messageOption(request.message || `Allow ${request.action ?? "this action"}${resources ? `: ${resources}` : ""}?`),
    ])
  }

  const askQuestion = (form) => {
    waiting.add(form.id)
    remember()
    // The question tool titles every form "Questions" and each field with a short
    // header; the field description is the question itself.
    const asked = (Array.isArray(form.fields) ? form.fields : [])
      .filter((field) => !field?.hidden)
      .map((field) => field?.description || field?.title)
      .filter(Boolean)
      .join("\n")
    send("needs-input", tracked, [
      "--notify", "--title", "OpenCode", "--body", "Question", "--reason", "question",
      ...messageOption(asked || form.title),
    ])
  }

  const listOf = (read) => {
    const list = attempt(read, [])
    return Array.isArray(list) ? list : []
  }

  const familyOf = (root) => {
    const family = listOf(() => data.session.family(root))
    return family.includes(root) ? family : [root, ...family]
  }

  // Approvals and questions open in the conversation or its subagents.
  const openPrompts = (root) => familyOf(root).flatMap((sessionID) => [
    ...listOf(() => data.session.permission.list(sessionID))
      .filter((request) => request?.id).map((request) => ({ id: request.id, ask: () => askApproval(request) })),
    ...listOf(() => data.session.form.list(sessionID))
      .filter((form) => form?.id).map((form) => ({ id: form.id, ask: () => askQuestion(form) })),
  ])

  // Returning to a conversation, or reconnecting, brings no new event for the
  // prompts already open in it.
  const askPending = (root) => {
    const prompts = openPrompts(root)
    for (const prompt of prompts) {
      if (!waiting.has(prompt.id)) prompt.ask()
    }
    return prompts.length > 0
  }

  // The TUI loads open prompts lazily; check again once they are synced.
  const syncPending = (root) => {
    const syncs = familyOf(root).flatMap((sessionID) => [
      attempt(() => data.session.permission.sync(sessionID), undefined),
      attempt(() => data.session.form.sync(sessionID), undefined),
    ]).map((sync) => Promise.resolve(sync).catch(() => {}))
    Promise.all(syncs).then(() => {
      if (tracked === root) askPending(root)
    })
  }

  // Follows the conversation on screen: a new session, a resumed one, or another tab.
  const followRoute = () => {
    const route = attempt(() => context.ui.router.current(), undefined)
    if (route?.type !== "session" || !route.sessionID) return
    const root = rootOf(route.sessionID)
    if (!root || root === tracked) return
    tracked = root
    waiting.clear()
    active = isRunning(root)
    remember()
    if (!askPending(root)) send(active ? "running" : "ready", root)
    syncPending(root)
  }

  // The running state of a conversation the TUI just connected to can arrive
  // after it is on screen, with no execution event for a turn already underway.
  const refresh = () => {
    followRoute()
    if (!tracked || active || !isRunning(tracked)) return
    active = true
    remember()
    if (!askPending(tracked)) send("running", tracked)
  }

  const owns = (sessionID) => {
    followRoute()
    return Boolean(sessionID) && sessionID === tracked
  }
  const concerns = (sessionID) => {
    followRoute()
    return Boolean(sessionID && tracked) && rootOf(sessionID) === tracked
  }

  // A subagent's report wakes its parent again, so the parent is not done yet.
  const hasRunningChild = (sessionID) =>
    familyOf(sessionID).some(
      (child) => child !== sessionID && data.session.get(child)?.parentID === sessionID && isRunning(child),
    )

  const lastReply = (sessionID) => {
    const messages = attempt(() => data.session.message.list(sessionID), [])
    for (let index = messages.length - 1; index >= 0; index--) {
      const message = messages[index]
      if (message?.type !== "assistant") continue
      const text = (message.content ?? [])
        .filter((part) => part?.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim()
      if (text) return text
    }
    return undefined
  }

  const resolved = (id) => {
    if (!waiting.delete(id)) return
    remember()
    if (waiting.size > 0 || !active) return
    send("running", tracked)
  }

  const handlers = {
    "session.execution.started": (event) => {
      if (!owns(event.data?.sessionID)) return
      active = true
      // Another subagent finishing wakes the conversation too; a prompt still
      // open in one of them keeps it waiting.
      const open = new Set(openPrompts(tracked).map((prompt) => prompt.id))
      for (const id of waiting) {
        if (!open.has(id)) waiting.delete(id)
      }
      remember()
      if (waiting.size === 0) send("running", tracked)
    },
    "server.connected": () => {
      if (tracked) syncPending(tracked)
    },
    "session.execution.succeeded": (event) => {
      const sessionID = event.data?.sessionID
      if (!active || !owns(sessionID) || hasRunningChild(sessionID)) return
      active = false
      remember()
      send("needs-input", sessionID, [
        "--notify", "--title", "OpenCode", "--body", "Response ready", "--reason", "turn",
        ...messageOption(lastReply(sessionID)),
      ])
    },
    "session.execution.interrupted": (event) => {
      if (!active || !owns(event.data?.sessionID)) return
      active = false
      remember()
      send("needs-input", tracked, ["--body", "Interrupted", "--reason", "turn"])
    },
    "session.execution.failed": (event) => {
      if (!active || !owns(event.data?.sessionID)) return
      active = false
      remember()
      send("error", tracked, [
        "--notify", "--title", "OpenCode", "--body", "The agent stopped with an error",
        ...messageOption(event.data?.error?.message),
      ])
    },
    "permission.asked": (event) => {
      const request = event.data ?? {}
      if (!request.id || waiting.has(request.id) || !concerns(request.sessionID)) return
      askApproval(request)
    },
    "permission.replied": (event) => resolved(event.data?.requestID),
    "form.created": (event) => {
      const form = event.data?.form ?? {}
      if (!form.id || waiting.has(form.id) || !concerns(form.sessionID)) return
      askQuestion(form)
    },
    "form.replied": (event) => resolved(event.data?.id),
    "form.cancelled": (event) => resolved(event.data?.id),
  }

  const disposers = Object.entries(handlers).flatMap(([type, handle]) => {
    const dispose = attempt(() => data.on(type, (event) => {
      try {
        handle(event)
      } catch {
        // A malformed event is skipped, never surfaced in the TUI.
      }
    }), undefined)
    return typeof dispose === "function" ? [dispose] : []
  })

  // A reload continues the turn in progress instead of announcing a fresh start.
  if (!memory.started) send("ready", tracked ?? resumed)
  remember()
  followRoute()
  const timer = setInterval(refresh, ROUTE_POLL_MILLISECONDS)
  timer.unref?.()

  return () => {
    clearInterval(timer)
    for (const dispose of disposers.reverse()) dispose()
    globalThis[REGISTERED] = false
  }
}

export default { id: "soprano", setup: register }
