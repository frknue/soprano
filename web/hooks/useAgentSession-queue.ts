// omp owns the steering/follow-up queue: the panel renders its snapshots
// (`get_state.queuedMessages` and live `queue_update` events), so every
// client viewing the session shows the same queue.
import type { QueuedMessages } from "@/lib/pi-types";

export type { QueuedMessages };

export const EMPTY_QUEUE: QueuedMessages = { steering: [], followUp: [] };

/** Parse a queue snapshot from an RPC frame or state; null when absent. */
export function readQueueSnapshot(value: unknown): QueuedMessages | null {
  if (!value || typeof value !== "object" || !("steering" in value) || !("followUp" in value)) return null;
  const [steering, followUp] = [value.steering, value.followUp].map((list) =>
    Array.isArray(list) ? list.filter((item): item is string => typeof item === "string") : []);
  return { steering, followUp };
}
