// Loaded only for omp panes via --extension; does not modify the user's omp settings.
export default function (omp) {
  const binary = process.env.SOPRANO_BIN
  if (!binary) return

  const report = async (state, ctx, options = []) => {
    // Headless subagents inherit the pane environment but do not own its terminal.
    if (ctx.mode !== "tui") return
    const sessionId = ctx.sessionManager.getSessionId()
    const payload = JSON.stringify({ session_id: sessionId, cwd: ctx.cwd })
    try {
      const child = Bun.spawn(
        [binary, "agent-event", state, "--profile", "omp", ...options, "--message-json", payload],
        { env: process.env, stdin: "ignore", stdout: "ignore", stderr: "ignore" },
      )
      await child.exited
    } catch {
      // Status reporting must not interrupt the agent.
    }
  }

  omp.on("session_start", async (_event, ctx) => report("ready", ctx))
  omp.on("session_switch", async (_event, ctx) => report("ready", ctx))
  omp.on("session_branch", async (_event, ctx) => report("ready", ctx))
  omp.on("agent_start", async (_event, ctx) => report("running", ctx))
  omp.on("agent_end", async (event, ctx) => {
    if (event.willContinue) return
    const lastAnswer = event.messages.findLast((message) => message.role === "assistant")
    const text = lastAnswer?.content?.filter((part) => part.type === "text")
      .map((part) => part.text).join("\n").slice(0, 4096)
    await report("needs-input", ctx, [
      "--notify", "--title", "omp", "--body", "Response ready",
      ...(text ? ["--message-json", JSON.stringify({ message: text })] : []),
    ])
  })
  omp.on("tool_approval_requested", async (event, ctx) => {
    if (event.sessionId !== ctx.sessionManager.getSessionId()) return
    await report("needs-input", ctx, [
      "--notify", "--title", "omp", "--body", "Approval required",
      "--message-json", JSON.stringify({ message: event.reason || `Approve ${event.toolName}?` }),
    ])
  })
  omp.on("tool_approval_resolved", async (event, ctx) => {
    if (event.sessionId === ctx.sessionManager.getSessionId()) await report("running", ctx)
  })
  omp.on("session_shutdown", async (_event, ctx) => report("stopped", ctx))
}
