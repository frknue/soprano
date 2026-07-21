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

export const SopranoNotificationPlugin = async () => {
  await sendEvent("ready")

  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.status":
          if (event.properties?.status?.type === "busy") {
            await sendEvent("running")
          } else if (event.properties?.status?.type === "idle") {
            await sendEvent("ready")
          }
          break
        case "session.idle":
          await sendEvent("ready", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Ready for a prompt",
          ])
          break
        case "permission.asked":
          await sendEvent("needs-input", [
            "--notify",
            "--title", "OpenCode",
            "--body", "Approval required",
          ])
          break
        case "session.error":
          await sendEvent("error", [
            "--notify",
            "--title", "OpenCode",
            "--body", "The agent stopped with an error",
          ])
          break
      }
    },
  }
}
