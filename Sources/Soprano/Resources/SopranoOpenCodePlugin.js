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

export const SopranoNotificationPlugin = async () => {
  await sendEvent("ready")

  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.status":
          if (event.properties?.status?.type === "busy") {
            await sendEvent("running")
          }
          break
        case "session.idle":
          await sendEvent("needs-input", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Response ready",
            ...payloadOf(event),
          ])
          break
        case "permission.asked":
          await sendEvent("needs-input", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Approval required",
            ...payloadOf(event),
          ])
          break
        case "session.error":
          await sendEvent("error", [
            "--notify",
            "--title", "OpenCode",
            "--body", "The agent stopped with an error",
            ...payloadOf(event),
          ])
          break
      }
    },
  }
}
