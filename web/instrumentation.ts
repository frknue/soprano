export async function register(): Promise<void> {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    // Keep Node-only modules out of the Edge instrumentation bundle.
    const { register: registerNode } = await import("./instrumentation.node");
    await registerNode();
  }
}
