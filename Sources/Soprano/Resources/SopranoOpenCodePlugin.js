// Launch-scoped Soprano integration. TerminalConfig adds this plugin through
// OPENCODE_CONFIG_CONTENT, so the user's OpenCode configuration is untouched.

const sendEvent = async (state, options = []) => {
  const binary = process.env.SOPRANO_BIN
  if (!binary) return

  try {
    const processHandle = Bun.spawn(
      [binary, "agent-event", state, ...options],
      {
        env: process.env,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
      },
    )
    await processHandle.exited
  } catch {
    // Agent telemetry must never interfere with OpenCode.
  }
}

// Hands the event's own properties to Soprano, which reads whichever known
// message key is present. Forwarding the payload rather than a fixed string is
// what lets a banner quote the permission OpenCode is actually asking about.
const payloadOf = (event) => {
  try {
    const properties = event?.properties
    if (!properties) return []
    return ["--message-json", JSON.stringify(properties)]
  } catch {
    // A payload that will not serialize must not cost us the notification.
    return []
  }
}

export const SopranoNotificationPlugin = async ({ client, directory } = {}) => {
  const sessions = new Map()
  let activeSessionID = process.env.SOPRANO_RESUME_SESSION_ID

  const rootSession = async (sessionID) => {
    if (!sessionID) return
    try {
      let info = sessions.get(sessionID)
      if (!info) {
        info = (await client.session.get({ path: { id: sessionID } }))?.data
        if (info) sessions.set(sessionID, info)
      }
      // Subagents share this plugin. Their conversations must never replace
      // the main conversation saved for the terminal.
      return info && !info.parentID ? info : undefined
    } catch {
      return undefined
    }
  }

  const conversationPayload = (info) => [
    "--message-json",
    JSON.stringify({ sessionID: info.id, cwd: info.directory ?? directory }),
  ]

  await sendEvent("ready")

  return {
    "chat.message": async ({ sessionID }) => {
      const info = await rootSession(sessionID)
      if (!info) return
      activeSessionID = info.id
      await sendEvent("running", conversationPayload(info))
    },
    event: async ({ event }) => {
      if (event.type === "session.created" || event.type === "session.updated") {
        const info = event.properties?.info
        if (!info?.id) return
        sessions.set(info.id, info)
        if (event.type === "session.created" && !info.parentID) {
          activeSessionID = info.id
          await sendEvent("ready", conversationPayload(info))
        }
        return
      }
      if (!["session.status", "session.idle", "permission.asked", "session.error"].includes(event.type)) return
      const info = await rootSession(event.properties?.sessionID)
      if (!info || (activeSessionID && activeSessionID !== info.id)) return
      activeSessionID = info.id
      const conversation = conversationPayload(info)
      switch (event.type) {
        case "session.status":
          if (event.properties?.status?.type === "busy") {
            await sendEvent("running", conversation)
          }
          break
        case "session.idle":
          await sendEvent("needs-input", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Response ready",
            ...conversation,
            ...payloadOf(event),
          ])
          break
        case "permission.asked":
          await sendEvent("needs-input", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Approval required",
            ...conversation,
            ...payloadOf(event),
          ])
          break
        case "session.error":
          await sendEvent("error", [
            "--notify",
            "--title", "OpenCode",
            "--body", "The agent stopped with an error",
            ...conversation,
            ...payloadOf(event),
          ])
          break
      }
    },
  }
}
