import { getDisplayableAssistantBlocks } from "./message-display";
import type { AgentMessage, AssistantContentBlock, AssistantMessage, CustomMessage } from "./types";

/**
 * Lightweight transcript row planner for ChatWindow's committed transcript.
 *
 * The O(n) grouping pass only inspects roles/blocks and produces plain row
 * descriptors; element creation happens later for the visible window only.
 *
 * Rows are appended in transcript order; a row is either:
 * - { kind: "message", index } — one message rendered standalone (messages
 *   before the first anchor, or a turn with nothing to fold)
 * - { kind: "group", userIndex, endIndex, segments } — one anchored turn. Like
 *   the omp TUI, agent text is never hidden: the turn renders as its anchor
 *   followed by `segments` in order, where each run of activity (thinking,
 *   tool calls, notices) between two pieces of text folds into one collapsed
 *   row. A turn stays one row so the render-window math is unchanged.
 */

/** A folded activity entry: the listed blocks of an assistant message, or a whole non-assistant message. */
export type ActivityPiece = { index: number; blocks?: AssistantContentBlock[] };

export type TranscriptSegment =
  /** Visible agent text/images from one assistant message. `last` marks text
   *  that ends its message; only that segment carries usage and the error. */
  | { kind: "text"; index: number; blocks: AssistantContentBlock[]; last: boolean }
  | { kind: "activity"; pieces: ActivityPiece[]; stepCount: number; toolCallCount: number };

export type TranscriptRow =
  | { kind: "message"; index: number }
  | { kind: "group"; userIndex: number; endIndex: number; segments: TranscriptSegment[] };

export interface PlanOptions {
  /** Mirrors omp's `hideThinkingBlock`: drop thinking blocks entirely. */
  hideThinking?: boolean;
}

// A user message normally anchors a turn. When compaction fires mid-turn, pi
// drops the original user prompt and inserts a compaction summary (role
// "custom", customType "compaction") in its place; the agent then keeps
// producing tool calls and answers with no user message left to anchor them.
// Treat a compaction summary as an anchor too, otherwise every
// post-compaction message renders standalone and never folds.
export function isGroupAnchor(message: AgentMessage): boolean {
  if (message.role === "user") return true;
  return message.role === "custom" && (message as CustomMessage).customType === "compaction";
}

/** Split one anchored turn into text and folded-activity segments. */
export function planTurnSegments(
  messages: AgentMessage[],
  userIdx: number,
  endIdx: number,
  options: PlanOptions = {},
): TranscriptSegment[] {
  const segments: TranscriptSegment[] = [];
  let activity: Extract<TranscriptSegment, { kind: "activity" }> | null = null;
  const addActivity = (piece: ActivityPiece, toolCalls: number) => {
    if (!activity) {
      activity = { kind: "activity", pieces: [], stepCount: 0, toolCallCount: 0 };
      segments.push(activity);
    }
    activity.pieces.push(piece);
    activity.stepCount += 1;
    activity.toolCallCount += toolCalls;
  };

  for (let idx = userIdx + 1; idx < endIdx; idx++) {
    const msg = messages[idx];
    // Tool results render inline under their tool call inside the fold.
    if (msg.role === "toolResult") continue;
    // Mount notices never render; counting them would show an empty fold.
    if (msg.role === "custom" && (msg as CustomMessage).customType === "xdev-mount-notice") continue;
    if (msg.role !== "assistant") {
      // Job results, reminders, and other notices are activity, as in the TUI.
      addActivity({ index: idx }, 0);
      continue;
    }
    const assistant = msg as AssistantMessage;
    let blocks = getDisplayableAssistantBlocks(assistant);
    if (options.hideThinking) blocks = blocks.filter((block) => block.type !== "thinking");
    let lastText: Extract<TranscriptSegment, { kind: "text" }> | null = null;
    let text: AssistantContentBlock[] = [];
    let other: AssistantContentBlock[] = [];
    const flushText = () => {
      if (text.length === 0) return;
      lastText = { kind: "text", index: idx, blocks: text, last: false };
      segments.push(lastText);
      activity = null;
      text = [];
    };
    const flushOther = () => {
      if (other.length === 0) return;
      addActivity({ index: idx, blocks: other }, other.filter((block) => block.type === "toolCall").length);
      other = [];
    };
    for (const block of blocks) {
      if (block.type === "image" || (block.type === "text" && block.text.trim().length > 0)) {
        flushOther();
        text.push(block);
      } else if (block.type !== "text") {
        flushText();
        other.push(block);
      }
    }
    flushText();
    flushOther();
    // A provider error must stay visible: when the message ended in activity,
    // it gets its own (empty) text segment to carry the error.
    if (assistant.errorMessage?.trim() && segments.at(-1) !== lastText) {
      lastText = { kind: "text", index: idx, blocks: [], last: false };
      segments.push(lastText);
      activity = null;
    }
    // Text that ends its message carries the message's usage and error.
    if (lastText && segments.at(-1) === lastText) (lastText as Extract<TranscriptSegment, { kind: "text" }>).last = true;
  }
  return segments;
}

/**
 * True when the tail of the transcript looks mid-run, without asking the owning
 * process. omp-web receives SSE frames only for runs it spawned itself, so a
 * session driven by a separate `omp` process had no signal at all and its
 * in-progress turn was always folded into "Process details" (#136).
 *
 * Mid-run has exactly two shapes: a tool result just landed and the agent is
 * about to continue, or an assistant message ends with a tool call whose result
 * has not arrived yet. A finished turn ends in text, so it stops counting.
 */
export function looksLikeRunningTurn(messages: AgentMessage[]): boolean {
  const last = messages[messages.length - 1];
  if (!last) return false;
  if (last.role === "toolResult") return true;
  if (last.role !== "assistant") return false;
  // A failed or cancelled turn is finished however its blocks are shaped.
  if (last.errorMessage || last.stopReason === "aborted" || last.stopReason === "error") return false;
  const blocks = getDisplayableAssistantBlocks(last as AssistantMessage);
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    const block = blocks[i];
    // Whitespace-only text does not close a turn; look past it.
    if (block.type === "text" && block.text.trim().length === 0) continue;
    return block.type === "toolCall";
  }
  return false;
}

/**
 * Plan the transcript into lightweight row descriptors WITHOUT creating
 * React elements. O(history) but allocates only small objects.
 */
export function planTranscriptRows(messages: AgentMessage[], options: PlanOptions = {}): TranscriptRow[] {
  const rows: TranscriptRow[] = [];
  for (let idx = 0; idx < messages.length;) {
    if (!isGroupAnchor(messages[idx])) {
      rows.push({ kind: "message", index: idx });
      idx += 1;
      continue;
    }
    const userIdx = idx;
    let endIdx = userIdx + 1;
    while (endIdx < messages.length && !isGroupAnchor(messages[endIdx])) endIdx += 1;
    const segments = planTurnSegments(messages, userIdx, endIdx, options);
    if (segments.some((segment) => segment.kind === "activity")) {
      rows.push({ kind: "group", userIndex: userIdx, endIndex: endIdx, segments });
    } else {
      // Nothing to fold: render the anchor and the rest as standalone messages.
      for (let renderIdx = userIdx; renderIdx < endIdx; renderIdx++) rows.push({ kind: "message", index: renderIdx });
    }
    idx = endIdx;
  }
  return rows;
}
