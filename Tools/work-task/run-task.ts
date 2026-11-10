/**
 * work-task: Agent SDK hand-off.
 *
 * Autonomously works a single plans-cc task via the Claude Agent SDK. The
 * `--mode` flag selects which skill drives the run:
 *   - `execute`  (default): drives `plan-execute` to implement the task,
 *                always in `worktree` isolation, leaving it in `review`. Accepts
 *                an OPTIONAL `--description`: when the task is still pending
 *                (un-elaborated), `plan-execute` auto-elaborates it inline and the
 *                guidance is folded into that elaboration pass (direct-execute,
 *                #088); it is simply absent for a bare execute of an already
 *                elaborated plan.
 *
 * The valueless `--keep` flag (#078) requests that the worktree be KEPT after an
 * execute run rather than cleaned up. It is threaded into the execute-bearing
 * prompt builders (buildExecutePrompt / buildExecuteYoloPrompt), which append a
 * trailing ` keep` token to the `/plan-execute … worktree` command line. It is
 * orthogonal to `--mode` and ignored by non-execute builders.
 *   - `elaborate`: drives `plan-elaborate` to research/flesh out a pending
 *                task autonomously (no interactive prompts). Accepts an OPTIONAL
 *                `--description` folded in as the user's guidance for the pass.
 *   - `reElaborate`: drives `plan-elaborate` (Path C, further elaboration) on an
 *                already-elaborated task, folding in user-provided `--description`
 *                guidance to refine/add to the plan, leaving it `elaborated`. This
 *                is the only mode that REQUIRES both `--task-id` and
 *                `--description`.
 *   - `capture`: drives `plan-capture` to record a new task from a free-text
 *                `--description`, leaving it in `pending` (no chaining).
 *   - `captureElaborate`: drives `plan-capture` then chains into
 *                `plan-elaborate` to record AND flesh out a new task from a
 *                free-text `--description`, leaving it in `elaborated` (it does
 *                NOT execute).
 *   - `backlog`: drives `plan-backlog` to defer an existing task, moving its
 *                file from `.plans/pending/` into `.plans/backlog/`. Requires
 *                `--task-id`; carries no description.
 *   - `restore`: drives `plan-restore` to bring a deferred task back, moving its
 *                file from `.plans/backlog/` into `.plans/pending/` while
 *                PRESERVING its status. Requires `--task-id`; no description.
 *   - `executeYolo`: drives `plan-execute "<description>" yolo` to auto-capture,
 *                auto-elaborate, and autonomously execute a new task from a
 *                free-text `--description` in an isolated worktree, leaving it in
 *                `review`.
 * This process is the SOLE writer of the project's `.plans/` directory and git
 * tree — the Plans.app itself is a strictly read-only viewer.
 *
 * Auth: relies on the inherited `claude login` credential from ~/.claude/.
 * We deliberately do NOT set ANTHROPIC_API_KEY.
 *
 * Output contract: NDJSON on stdout, one JSON object per line:
 *   {"kind":"activity","tool":"Edit","detail":"…"}
 *   {"kind":"text","chunk":"…"}
 *   {"kind":"denied","tool":"mcp__sentry__…"}
 *   {"kind":"session","sessionId":"…"}
 *   {"kind":"reply","text":"…","sessionId":"…"}
 *   {"kind":"captured","taskId":"NNN"}
 *   {"kind":"question","toolUseId":"…","questions":[…]}
 *   {"kind":"done","costUsd":N,"turns":N,"stopReason":"…"}
 *   {"kind":"error","message":"…"}
 * The `question` line (task #083) is emitted ONLY by a `review` run, when the
 * guided `plan-review` skill asks via `AskUserQuestion`. The run PARKS until the
 * Swift app writes a matching `{"kind":"answer","toolUseId":…,"answers":{…}}`
 * line back on stdin — the one place this process reads stdin, and only in
 * review mode.
 * `session` is emitted once, at the start of a run, with the Agent SDK session
 * id; `reply` is emitted on a successful result, immediately before `done`, and
 * carries the agent's clean final answer (the `text` chunks also include
 * intermediate narration). A `discuss` run can be continued as a follow-up turn
 * by passing that session id back via `--resume <id>`.
 * The `denied` line is a NON-fatal signal (task #092): a tool call the agent
 * reached for was refused because it wasn't on the allowlist. The run still
 * continues and finishes normally — this is a distinct signal from `error`.
 * The `captured` line is a NON-fatal signal (task #100) emitted ONCE by the
 * NEW-TASK modes (`captureElaborate` / `executeYolo`): it carries the real task
 * id the run just created, letting the Swift side re-key the live capture
 * spinner to the real plan row directly instead of inferring the id from an
 * ambiguous baseline diff (which strands when two captures overlap). The run
 * continues and finishes normally after reporting.
 * Raw SDK message shapes are never emitted; they are mapped to the above.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// Hard ceiling on spend. Under subscription (claude login) auth the real bound
// is the plan; this ceiling is the safety net for API-key fallback. Raised to
// $40 so a single autonomous execute run is far less likely to hit the cap
// mid-task and strand the task at in-progress before it reaches review.
const MAX_BUDGET_USD = 40.0;

// Per-turn ceiling for a `discuss` run. Discussion is read-only Q&A and each
// resumed turn re-sends the growing conversation history, so it gets a much
// lower cap than a full autonomous execute run.
const DISCUSS_MAX_BUDGET_USD = 5.0;

// Stop reasons that mean the run was cut short by a cap (budget/turn limit)
// rather than finishing. These truncation reasons are the more actionable cause
// and are handled downstream — the stranded-at-in-progress guard must NOT
// override them.
const truncatingStopReasons = new Set([
  "error_max_budget_usd",
  "error_max_turns",
]);

/** What the spawned agent should do with the task. */
type Mode =
  | "execute"
  | "elaborate"
  | "reElaborate"
  | "reElaborateReview"
  | "capture"
  | "captureElaborate"
  | "executeYolo"
  | "delete"
  | "backlog"
  | "restore"
  | "discuss"
  | "review";

/**
 * Where a `review` run should look for the work to review (#083). `kept` reviews
 * the task's kept execution worktree (read from the task file's `**Worktree:**`
 * field); `worktree` creates a throwaway worktree off the task's branch; `main`
 * reviews the branch checked out in the main tree. Only `worktree` ever puts the
 * word "worktree" in the prompt — the `plan-review` skill keyword-matches it.
 */
type ReviewLocation = "kept" | "worktree" | "main";

interface Args {
  projectRoot: string;
  /** Required for execute/elaborate/reElaborate/delete; undefined for capture/captureElaborate/executeYolo (no task exists yet). */
  taskId?: string;
  mode: Mode;
  /**
   * The free-text description/guidance to act on. Required for
   * capture/captureElaborate/executeYolo AND reElaborate; OPTIONAL for
   * elaborate and execute (folded into the prompt as user guidance when
   * present — for execute it feeds the inline auto-elaboration of a pending
   * plan, #088).
   */
  description?: string;
  /**
   * Optional (#065). When true, the elaborate-bearing prompt builders
   * (buildElaboratePrompt / buildReElaboratePrompt / buildCaptureElaboratePrompt)
   * append a trailing ` deep` token to the `/plan-elaborate <id>` line, requesting
   * a deeper elaboration pass. Orthogonal to `mode`; ignored by non-elaborate
   * builders.
   */
  deep?: boolean;
  /**
   * Optional (#078). When true, the execute-bearing prompt builders
   * (buildExecutePrompt / buildExecuteYoloPrompt) append a trailing ` keep` token
   * to the `/plan-execute … worktree` line, requesting that the worktree be kept
   * after the run rather than cleaned up. Orthogonal to `mode`; ignored by
   * non-execute builders.
   */
  keep?: boolean;
  /**
   * Optional, `discuss` only. An Agent SDK session id from a previous turn's
   * `session`/`reply` line; when present the run resumes that session so the
   * agent keeps the conversation's context, and the follow-up prompt is used
   * instead of the first-turn `/plan-discuss` prompt.
   */
  resume?: string;
  /**
   * Optional (#114), `discuss` only — and only meaningful for a PER-PLAN
   * discuss (a non-empty task id). When true this per-plan discuss turn is
   * APPLY-enabled: the runner swaps its read-only discuss prompt for one that
   * PERMITS applying the agreed change to this plan's file via `plan-discuss`,
   * and swaps the read-only allowlist for a write-capable one. The DEFAULT
   * discuss path (apply undefined/false) stays byte-for-byte read-only.
   * Orthogonal to `mode`; ignored outside discuss.
   */
  apply?: boolean;
  /**
   * Required for `review` (#083), ignored otherwise. Selects which checkout the
   * guided `plan-review` run should inspect — the task's kept worktree, a fresh
   * throwaway worktree, or the main tree. Carried as a value flag
   * (`--review-location kept|worktree|main`).
   */
  reviewLocation?: ReviewLocation;
}

/** Emit one NDJSON line on stdout. Never pretty-printed. */
function emit(obj: Record<string, unknown>): void {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function emitError(message: string): void {
  emit({ kind: "error", message });
}

/** Tiny hand-rolled argv parser. Returns null if a required flag is missing. */
function parseArgs(argv: string[]): Args | null {
  let projectRoot: string | undefined;
  let taskId: string | undefined;
  let description: string | undefined;
  let mode: Mode = "execute";
  // #065: valueless flag requesting a deeper elaborate pass. Orthogonal to mode.
  let deep = false;
  // #078: valueless flag requesting the worktree be kept after execute. Orthogonal to mode.
  let keep = false;
  // #114: valueless flag opting a per-plan discuss turn OUT of read-only, so it may
  // apply the agreed change. Only meaningful alongside `--mode discuss`.
  let apply = false;
  let resume: string | undefined;
  // #083: value flag selecting the review target. Required when mode is review.
  let reviewLocation: ReviewLocation | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--project-root") {
      projectRoot = argv[++i];
    } else if (arg === "--task-id") {
      taskId = argv[++i];
    } else if (arg === "--description") {
      description = argv[++i];
    } else if (arg === "--review-location") {
      const value = argv[++i];
      if (value !== "kept" && value !== "worktree" && value !== "main") {
        return null;
      }
      reviewLocation = value;
    } else if (arg === "--resume") {
      resume = argv[++i];
      if (!resume) {
        return null;
      }
    } else if (arg === "--deep") {
      // Valueless flag — do NOT consume the following argv token.
      deep = true;
    } else if (arg === "--keep") {
      // Valueless flag — do NOT consume the following argv token.
      keep = true;
    } else if (arg === "--apply") {
      // Valueless flag — do NOT consume the following argv token.
      apply = true;
    } else if (arg === "--mode") {
      const value = argv[++i];
      if (
        value !== "execute" &&
        value !== "elaborate" &&
        value !== "reElaborate" &&
        value !== "reElaborateReview" &&
        value !== "capture" &&
        value !== "captureElaborate" &&
        value !== "executeYolo" &&
        value !== "delete" &&
        value !== "backlog" &&
        value !== "restore" &&
        value !== "discuss" &&
        value !== "review"
      ) {
        return null;
      }
      mode = value;
    }
  }

  if (!projectRoot) {
    return null;
  }

  // Session resume only makes sense for the conversational discuss mode; every
  // other mode is a one-shot lifecycle action, so reject it rather than
  // silently ignoring it.
  if (resume !== undefined && mode !== "discuss") {
    return null;
  }

  if (
    mode === "capture" ||
    mode === "captureElaborate" ||
    mode === "executeYolo"
  ) {
    // Capture / captureElaborate / executeYolo create a brand-new task, so
    // there is no task id yet; a free-text description is required instead.
    if (!description) {
      return null;
    }
    return { projectRoot, mode, description, deep, keep };
  }

  if (mode === "reElaborate") {
    // reElaborate operates on an EXISTING task AND carries free-text refinement
    // guidance, so it REQUIRES both a task id and a description.
    if (!taskId || !description) {
      return null;
    }
    return { projectRoot, taskId, mode, description, deep, keep, resume };
  }

  if (mode === "discuss") {
    // discuss carries a free-text question and REQUIRES a description (#099: a
    // discuss with no question is meaningless). Its task id is OPTIONAL (#110):
    // when present the discussion is scoped to that single task's plan; when
    // absent it is a WHOLE-PROJECT / whole-backlog discussion. A discuss with a
    // description but no `--task-id` therefore parses successfully, carrying an
    // undefined taskId through to the prompt builders.
    if (!description) {
      return null;
    }
    return { projectRoot, taskId, mode, description, deep, keep, resume, apply };
  }

  if (mode === "review") {
    // review (#083) operates on an EXISTING task and REQUIRES a review location
    // (kept/worktree/main). It carries no free-text description — the interactive
    // Q&A flows over stdin, not through the prompt.
    if (!taskId || !reviewLocation) {
      return null;
    }
    return { projectRoot, taskId, mode, reviewLocation };
  }

  // execute / elaborate / reElaborateReview / delete / backlog / restore operate
  // on an existing task, so a task id is the only REQUIRED argument. elaborate,
  // execute, and reElaborateReview additionally accept an OPTIONAL `--description`
  // (the user's guidance for the pass); it is folded in when present and simply
  // absent otherwise, so a bare `--mode elaborate --task-id <id>`,
  // `--mode execute --task-id <id>`, or `--mode reElaborateReview --task-id <id>`
  // behaves exactly as the un-guided pass. For execute (#088) the guidance feeds
  // the inline auto-elaboration of a pending plan; for reElaborateReview (#091) it
  // drives the re-elaboration after the plan is reset to pending. delete / backlog
  // / restore carry no free text at all.
  if (!taskId) {
    return null;
  }
  if (
    mode === "elaborate" ||
    mode === "execute" ||
    mode === "reElaborateReview"
  ) {
    return { projectRoot, taskId, mode, description, deep, keep };
  }
  return { projectRoot, taskId, mode, deep, keep };
}

/**
 * Derive a short, human-readable detail string for a tool_use block, without
 * leaking the full raw SDK input shape into our contract.
 */
function toolDetail(input: unknown): string {
  if (input === null || typeof input !== "object") {
    return "";
  }
  const o = input as Record<string, unknown>;
  // Prefer the fields most tools surface as their "subject".
  const candidates = [
    o.file_path,
    o.path,
    o.command,
    o.pattern,
    o.description,
    o.prompt,
    o.url,
    o.query,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.length > 0) {
      return c.length > 200 ? c.slice(0, 197) + "…" : c;
    }
  }
  return "";
}

/**
 * Flatten a `tool_result` block's `content` to a single string for substring
 * inspection (task #092). The SDK models tool-result content as EITHER a plain
 * string OR an array of content blocks (`{type:"text", text:"…"}`); we coerce
 * both to text so the permission-denial marker can be detected uniformly.
 */
export function toolResultText(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (typeof b === "string") return b;
        if (b && typeof b === "object" && typeof (b as Record<string, unknown>).text === "string") {
          return (b as Record<string, unknown>).text as string;
        }
        return "";
      })
      .join("");
  }
  return "";
}

/**
 * Decide whether a `user`-message content block is a genuine permission DENIAL
 * (task #116). A denial is counted ONLY when the block is a `tool_result` that
 * is itself an error (`is_error === true`) AND whose flattened text carries the
 * SDK's exact denial wording `Claude requested permissions to use`. This is
 * deliberately strict: a SUCCESSFUL read whose content merely quotes that
 * phrase (e.g. a file or log line that mentions permissions) must NOT be
 * flagged as a denial. Defensive about the unknown block shape — never throws.
 */
export function isPermissionDenial(block: unknown): boolean {
  if (!block || typeof block !== "object") {
    return false;
  }
  const rec = block as Record<string, unknown>;
  if (rec.type !== "tool_result") {
    return false;
  }
  if (rec.is_error !== true) {
    return false;
  }
  return toolResultText(rec.content).includes(
    "Claude requested permissions to use",
  );
}

/**
 * Build the prompt for an `execute` run. Worktree isolation is mandatory: the
 * skill is invoked as `/plan-execute <id> worktree` so it can never fall back to
 * editing the main checkout in place — the Plans app only ever hands tasks off
 * for isolated execution.
 *
 * #078: when `keep` is true, a trailing ` keep` token is appended to the
 * `/plan-execute <id> worktree` command line so the worktree is kept after the
 * run rather than cleaned up.
 *
 * #088 (direct-execute): the task handed off may still be PENDING
 * (un-elaborated). `plan-execute` stops at an interactive "Not elaborated" gate
 * in that case, which the unattended runner cannot answer, so the prompt
 * pre-answers it — the agent is told to choose "Elaborate now" (auto-elaborate
 * inline, using the `deep` reasoning pass when requested) and THEN execute,
 * never silently skipping elaboration. `description` is OPTIONAL user guidance;
 * when present it is folded in as a `"""`-delimited block (mirroring
 * buildElaboratePrompt) and feeds that inline elaboration pass. When absent the
 * prompt is emitted without the guidance block, exactly as a bare
 * `/plan-execute <id>` hand-off always was.
 *
 * #116 (stranded subagents): this is a headless, single-turn run — ending the
 * turn ends the SDK query and kills any in-flight subagent. The prompt therefore
 * forbids backgrounding a delegated subagent (e.g. plan-executor) and then ending
 * the turn to "await a completion notification"; any delegation MUST run in the
 * foreground and be awaited inline within the same turn.
 */
function buildExecutePrompt(
  taskId: string,
  keep: boolean,
  deep: boolean,
  description?: string,
): string {
  const guidance = description?.trim()
    ? [
        `The user has provided the following guidance for this run — if the task`,
        `still needs elaborating, fold it into that inline elaboration pass as the`,
        `direction, and keep it in mind while executing. If the task is resuming`,
        `from review with its How checklist already complete, treat the guidance`,
        `as the additional work to do in this pass:`,
        "",
        `"""`,
        description.trim(),
        `"""`,
        "",
      ]
    : [];
  return [
    `Use the \`plan-execute\` skill to work the plans-cc task with id ${taskId}.`,
    `Invoke it in worktree mode: \`/plan-execute ${taskId} worktree${keep ? " keep" : ""}\`.`,
    "",
    ...guidance,
    "Requirements:",
    `1. The run MUST use a dedicated git worktree for task ${taskId} (the`,
    "   `worktree` argument above). Never edit the main checkout in place —",
    "   worktree isolation is mandatory for this hand-off.",
    `2. The task may still be un-elaborated (pending). If \`plan-execute\` reaches`,
    `   its not-elaborated gate (the "Execute anyway / Elaborate now" question),`,
    `   choose "Elaborate now": auto-elaborate the plan INLINE first${
      deep ? " (using a deep reasoning pass)" : ""
    },`,
    description?.trim()
      ? "   folding the guidance above into that elaboration, and THEN execute it."
      : "   and THEN execute it.",
    "   Never silently skip elaboration — a pending plan has no How checklist to",
    "   implement until it is elaborated.",
    "3. Implement the task fully, following the plan and the repository's",
    "   conventions (including TDD where a test suite exists).",
    "4. Run the targeted tests relevant to your changes and make them pass.",
    "5. When the work is complete and tests pass, move the task to the `review`",
    "   state. Do NOT mark it done — leave it in review for human verification.",
    "6. If you delegate any part of this work to a subagent (e.g. plan-executor),",
    "   you MUST run that subagent in the FOREGROUND and wait for it inline within",
    "   this same turn. NEVER spawn a background subagent and then end your turn to",
    "   await a completion notification — ending the turn ends this run and kills",
    "   the in-flight subagent, stranding the task at `in-progress`.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for an `elaborate` run. plan-elaborate is normally
 * interactive (it asks design questions via AskUserQuestion); since this is an
 * unattended hand-off with no UI to answer prompts, we instruct the agent to
 * elaborate autonomously, recording reasonable assumptions instead of asking.
 *
 * `description` is OPTIONAL user guidance for this pass. When present it is
 * folded in as a `"""`-delimited block (mirroring buildReElaboratePrompt) to
 * steer what the elaboration focuses on; when absent the prompt is emitted
 * unchanged, exactly as a bare `/plan-elaborate <id>` hand-off always was.
 */
function buildElaboratePrompt(
  taskId: string,
  deep: boolean,
  description?: string,
): string {
  const guidance = description?.trim()
    ? [
        `The user has provided the following guidance for this elaboration — fold`,
        `it into the plan as the direction for this pass:`,
        "",
        `"""`,
        description.trim(),
        `"""`,
        "",
      ]
    : [];
  return [
    `Use the \`plan-elaborate\` skill to research and flesh out the plans-cc`,
    `task with id ${taskId}:`,
    "",
    // #065: emit an explicit command line so the trailing ` deep` token (when
    // requested) sits END-ANCHORED as the final token on the invocation line,
    // matching the other two elaborate-bearing builders.
    `/plan-elaborate ${taskId}${deep ? " deep" : ""}`,
    "",
    ...guidance,
    "Requirements:",
    "1. Work fully autonomously. Do NOT ask the user any questions — there is",
    "   no interactive UI to answer them. Where the skill would prompt for a",
    "   design decision, make the most reasonable choice yourself and record it",
    "   in the task's Assumptions section (flagged as a discovered assumption).",
    "2. Research the codebase as needed and produce a complete How checklist,",
    "   Verification criteria, and Impact Scope per the skill's conventions.",
    "3. Leave the task in the `elaborated` state when done.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `reElaborate` run. This is plan-elaborate's Path C
 * ("further elaboration" of an already-elaborated task): we drive
 * `/plan-elaborate <id>` again on the existing task, but fold in user-provided
 * guidance text (the `description`) as the direction for what to add, refine, or
 * clarify. Like the other hand-offs this is unattended, so the agent must work
 * autonomously and record reasonable assumptions instead of asking. The task
 * stays in the `elaborated` state.
 */
function buildReElaboratePrompt(
  taskId: string,
  description: string,
  deep: boolean,
): string {
  return [
    `Use the \`plan-elaborate\` skill to FURTHER elaborate (Path C) the existing,`,
    `already-elaborated plans-cc task with id ${taskId}:`,
    "",
    // #065: trailing ` deep` token END-ANCHORED as the final token on the line.
    `/plan-elaborate ${taskId}${deep ? " deep" : ""}`,
    "",
    `The user has provided the following guidance for what to add, refine, or`,
    `clarify in this further elaboration — fold it into the plan as the direction`,
    `for this pass:`,
    "",
    `"""`,
    description,
    `"""`,
    "",
    "Requirements:",
    "1. Treat this as further elaboration of an ALREADY-elaborated task. Use the",
    "   guidance above to drive what changes — add the missing constraints, cases,",
    "   or redirection it describes, refining the How checklist, Verification",
    "   criteria, and Impact Scope accordingly.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them. Where the skill would prompt for a design",
    "   decision, make the most reasonable choice yourself and record it in the",
    "   task's Assumptions section (flagged as a discovered assumption).",
    "3. Research the codebase as needed to keep the plan accurate.",
    "4. Leave the task in the `elaborated` state when done. Do NOT execute it.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `reElaborateReview` run (#091). The plan is currently in
 * `review` / `in-review`; the user wants to throw the current plan away and
 * re-elaborate it from scratch. We FIRST reset the task file's `**Status:**`
 * header line back to `pending` IN PLACE (the file stays in `.plans/pending/`),
 * THEN drive `/plan-elaborate <id>` again so the whole plan is re-researched. An
 * OPTIONAL `description` is folded in as further direction for the elaboration.
 * Like the other hand-offs this is unattended, so the agent must work
 * autonomously and record reasonable assumptions instead of asking.
 */
function buildReviewReElaboratePrompt(
  taskId: string,
  deep: boolean,
  description?: string,
): string {
  const guidance = description?.trim()
    ? [
        `The user has provided the following guidance for this re-elaboration —`,
        `fold it into the plan as the direction for this pass:`,
        "",
        `"""`,
        description.trim(),
        `"""`,
        "",
      ]
    : [];
  return [
    `The plans-cc task with id ${taskId} is currently in review. The user wants to`,
    `send it BACK to pending and re-elaborate it from scratch. Do this in two`,
    `steps:`,
    "",
    `1. Edit the task's markdown file in \`.plans/pending/\` (its filename starts`,
    `   with ${taskId}-): change its \`**Status:**\` header line to read`,
    `   \`**Status:** pending\`. Leave the file where it is — do NOT move it out of`,
    `   \`.plans/pending/\`.`,
    `2. Then use the \`plan-elaborate\` skill to research and re-flesh out the task:`,
    "",
    // #065: trailing ` deep` token END-ANCHORED as the final token on the line,
    // matching the other elaborate-bearing builders.
    `/plan-elaborate ${taskId}${deep ? " deep" : ""}`,
    "",
    ...guidance,
    "Requirements:",
    "1. Perform the status reset to `pending` FIRST, before running the",
    "   elaboration, so `plan-elaborate` sees a pending task to work on.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them. Where the skill would prompt for a design",
    "   decision, make the most reasonable choice yourself and record it in the",
    "   task's Assumptions section (flagged as a discovered assumption).",
    "3. Research the codebase as needed and produce a complete How checklist,",
    "   Verification criteria, and Impact Scope per the skill's conventions.",
    "4. Leave the task in the `elaborated` state when done. Do NOT execute it.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `capture` run. plan-capture is normally interactive
 * (it asks clarifying questions before recording the task); since this is an
 * unattended hand-off with no UI to answer prompts, we instruct the agent to
 * capture autonomously, recording reasonable assumptions instead of asking, and
 * to capture ONLY — never chaining onward to elaborate or execute.
 */
function buildCapturePrompt(description: string): string {
  return [
    `Use the \`plan-capture\` skill to record a new plans-cc task from the`,
    `following description:`,
    "",
    `/plan-capture "${description}"`,
    "",
    "Requirements:",
    "1. Capture ONLY. Do NOT chain onward to elaborate or execute the task —",
    "   your job ends once the task is recorded.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is",
    "   no interactive UI to answer them. Where the skill would prompt for a",
    "   clarification, make the most reasonable assumption yourself and record",
    "   it in the task's Assumptions section.",
    "3. Leave the new task in the `pending` state.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `captureElaborate` run. This records a brand-new task
 * from the free-text description with `plan-capture`, then chains directly into
 * `plan-elaborate <new-id>` to research and flesh it out — leaving the task in
 * the `elaborated` state. It does NOT execute the task. Both skills are normally
 * interactive; since this is an unattended hand-off with no UI to answer
 * prompts, we instruct the agent to work autonomously, recording reasonable
 * assumptions instead of asking.
 */
function buildCaptureElaboratePrompt(
  description: string,
  deep: boolean,
): string {
  return [
    `Record a new plans-cc task from the following description, then flesh it`,
    `out — capture, then elaborate:`,
    "",
    `1. First, use the \`plan-capture\` skill to record the task:`,
    "",
    `   /plan-capture "${description}"`,
    "",
    `2. Then immediately use the \`plan-elaborate\` skill on the task you just`,
    `   captured, passing its new id:`,
    "",
    // #065: trailing ` deep` token END-ANCHORED as the final token on the line.
    `   /plan-elaborate <new-id>${deep ? " deep" : ""}`,
    "",
    "Requirements:",
    "1. Run BOTH steps in sequence: capture the task, then elaborate it. Do NOT",
    "   chain onward to execute the task — your job ends once the task is",
    "   elaborated.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is",
    "   no interactive UI to answer them. Where either skill would prompt for a",
    "   clarification or design decision, make the most reasonable assumption",
    "   yourself and record it in the task's Assumptions section.",
    "3. Research the codebase as needed and produce a complete How checklist,",
    "   Verification criteria, and Impact Scope per the skill's conventions.",
    "4. Leave the new task in the `elaborated` state when done. Do NOT execute",
    "   it.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for an `executeYolo` run. plan-execute accepts a free-text
 * description directly and, in `yolo` mode, auto-captures + auto-elaborates +
 * executes the new task fully autonomously in an isolated worktree (yolo implies
 * worktree + branch). The task is left in `review` for human verification — yolo
 * never marks it `completed`.
 *
 * #078: when `keep` is true, a trailing ` keep` token is appended to the
 * `/plan-execute "<description>" yolo` command line so the worktree is kept after
 * the run rather than cleaned up.
 *
 * #116 (stranded subagents): like buildExecutePrompt, this is a headless,
 * single-turn run — ending the turn kills any in-flight subagent. The prompt
 * forbids backgrounding a delegated subagent (e.g. plan-executor) and then ending
 * the turn to await a completion notification; delegation MUST run in the
 * foreground and be awaited inline within the same turn.
 */
function buildExecuteYoloPrompt(description: string, keep: boolean): string {
  return [
    `Use the \`plan-execute\` skill to autonomously work a brand-new plans-cc`,
    `task captured from the following description, in yolo mode:`,
    "",
    `/plan-execute "${description}" yolo${keep ? " keep" : ""}`,
    "",
    "Requirements:",
    "1. Run the FULL autonomous pipeline: auto-capture the description into a new",
    "   task, auto-elaborate it, then implement it. yolo mode is mandatory — it",
    "   runs in an isolated git worktree on its own branch. Never edit the main",
    "   checkout in place.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them. Where the pipeline would prompt for a",
    "   decision, make the most reasonable choice and record it as an assumption.",
    "3. Implement the task fully, following the plan and the repository's",
    "   conventions (including TDD where a test suite exists), and make the",
    "   targeted tests relevant to your changes pass.",
    "4. When the work is complete and tests pass, leave the task in the `review`",
    "   state. Do NOT mark it done — leave it in review for human verification.",
    "5. If you delegate any part of this work to a subagent (e.g. plan-executor),",
    "   you MUST run that subagent in the FOREGROUND and wait for it inline within",
    "   this same turn. NEVER spawn a background subagent and then end your turn to",
    "   await a completion notification — ending the turn ends this run and kills",
    "   the in-flight subagent, stranding the task at `in-progress`.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `delete` run. This drives `plan-delete <id>` to
 * permanently remove an existing task's plan file, state file, and PROGRESS.md
 * entries.
 *
 * plan-delete has TWO interactive gates, and this runner does NOT allowlist the
 * `AskUserQuestion` tool — so an unanswered gate would strand the run. Both are
 * therefore pre-answered in the prompt itself:
 *
 * 1. Step 6's "Are you sure you want to permanently delete task #NNN? (yes/no)"
 *    text confirm — answered "yes". The user already confirmed in-app before
 *    this run was spawned, so the in-app confirm IS the human gate.
 * 2. Step 7c's `AskUserQuestion` about deleting the task's associated git
 *    branch — answered "Keep branch". A single in-app click must never destroy
 *    git commits, so the branch is ALWAYS kept regardless of task state.
 */
function buildDeletePrompt(taskId: string): string {
  return [
    `Use the \`plan-delete\` skill to permanently delete the plans-cc task with`,
    `id ${taskId}:`,
    "",
    `/plan-delete ${taskId}`,
    "",
    "Requirements:",
    "1. The user has ALREADY confirmed this deletion in the app before this run",
    "   was started. When the skill asks \"Are you sure you want to permanently",
    `   delete task #${taskId}? (yes/no)\", the answer is YES — proceed with the`,
    "   deletion. Do NOT stop to re-confirm.",
    "2. KEEP the task's associated git branch. If the skill asks whether to",
    "   delete the branch, the answer is \"Keep branch\" — leave it exactly as-is.",
    "   Never run `git branch -D` or otherwise remove the branch: deleting a",
    "   branch would destroy commits, and that must never follow from a single",
    "   in-app click.",
    "3. Work fully autonomously. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them. Both of the skill's prompts are already",
    "   answered above; apply those answers and continue.",
    "4. Complete the rest of the skill's cleanup as normal: remove the task file,",
    "   remove its state file, and update PROGRESS.md (and HISTORY.md if the task",
    "   was completed).",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `backlog` run. This drives `plan-backlog <id>` to move
 * a deferred task's file from `.plans/pending/` into `.plans/backlog/`.
 *
 * The app gates this mode's button to `pending` / `elaborated` tasks only
 * (`PlanDetailView.canBacklog`), precisely so the skill's auto-pause path — which
 * commits dirty work with `git add -A` and checks out the default branch — can
 * never fire from a single in-app click. The prompt reinforces that boundary: if
 * the task somehow turns out to be active, STOP rather than pausing it, because
 * moving git state must never follow from one click.
 *
 * Note: `plan-backlog` is marked `disable-model-invocation: true`, so it is
 * user-invocable only. This prompt drives it via the `Skill` tool exactly as the
 * delete mode does. If that flag ever blocks the hand-off, the run will fail
 * loudly here rather than half-applying the move — the file move and the
 * PROGRESS.md edit are deliberately NOT inlined as a fallback, so there is one
 * implementation of the contract (the skill) and no chance of the two drifting.
 */
function buildBacklogPrompt(taskId: string): string {
  return [
    `Use the \`plan-backlog\` skill to defer the plans-cc task with id ${taskId}:`,
    "",
    `/plan-backlog ${taskId}`,
    "",
    "Requirements:",
    "1. The user has ALREADY chosen to backlog this task in the app, so proceed",
    "   without re-confirming. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them.",
    `2. Task #${taskId} is expected to be \`pending\` or \`elaborated\` (the app only`,
    "   offers this action for those statuses). If you find it is actually",
    "   `in-progress` or `in-review`, STOP and report that instead of pausing it:",
    "   the skill's auto-pause would commit uncommitted work and switch branches,",
    "   and that must never follow from a single in-app click.",
    "3. Complete the rest of the skill's work as normal: move the task file into",
    "   `.plans/backlog/`, and update PROGRESS.md.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `restore` run. This drives `plan-restore <id>` to move
 * a deferred task's file from `.plans/backlog/` back into `.plans/pending/`.
 *
 * Restore is the pure inverse of backlog and is non-destructive: it moves one
 * file and PRESERVES the task's existing status (a restored `elaborated` task
 * stays `elaborated`). It touches no git state, so it needs no in-app
 * confirmation and carries no status guard beyond the skill's own.
 *
 * Note: like `plan-backlog`, `plan-restore` is marked
 * `disable-model-invocation: true`. See `buildBacklogPrompt` for why the steps
 * are not inlined as a fallback.
 */
function buildRestorePrompt(taskId: string): string {
  return [
    `Use the \`plan-restore\` skill to bring the backlogged plans-cc task with`,
    `id ${taskId} back to the active list:`,
    "",
    `/plan-restore ${taskId}`,
    "",
    "Requirements:",
    "1. The user has ALREADY chosen to restore this task in the app, so proceed",
    "   without re-confirming. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them.",
    "2. PRESERVE the task's existing `**Status:**` exactly as it is. Restore is",
    "   the inverse of backlog, not a status change: a restored `elaborated` task",
    "   stays `elaborated`, a still-`pending` one stays `pending`.",
    "3. Complete the rest of the skill's work as normal: move the task file into",
    "   `.plans/pending/`, append the `**Restored:**` note, and update PROGRESS.md.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a `discuss` run (#099). This drives the `plan-discuss`
 * skill to ANSWER a free-text question. Unlike the lifecycle modes, discuss is
 * strictly READ-ONLY here: `plan-discuss` can apply changes to a plan on request,
 * but this hand-off MUST NOT — it answers the question and nothing more, leaving
 * every plan file untouched. The user's question is folded in as a `"""`-delimited
 * block (mirroring the other guidance-bearing builders). Like the other hand-offs
 * it is unattended, so the agent must work fully autonomously and never ask the
 * user anything.
 *
 * #110: the task id is now OPTIONAL. When `taskId` is non-empty the discussion is
 * scoped to that single task's plan (`/plan-discuss <id>`, the original #099
 * behaviour). When `taskId` is empty it is a WHOLE-PROJECT discussion: a bare
 * `/plan-discuss` (whole-backlog mode) with the copy reworded to talk about the
 * project's backlog / plans rather than one specific plan — the same strict
 * read-only and no-questions constraints apply in both forms.
 */
function buildDiscussPrompt(taskId: string, description: string): string {
  const scoped = taskId.length > 0;
  return [
    scoped
      ? `Use the \`plan-discuss\` skill to answer a question about the plans-cc task`
      : `Use the \`plan-discuss\` skill to answer a question about this project's`,
    scoped ? `with id ${taskId}:` : `plans-cc backlog (all of its plans, across every status):`,
    "",
    scoped ? `/plan-discuss ${taskId}` : `/plan-discuss`,
    "",
    scoped
      ? `The user has asked the following question about this plan — answer it:`
      : `The user has asked the following question about this project's backlog — answer it:`,
    "",
    `"""`,
    description,
    `"""`,
    "",
    "Requirements:",
    scoped
      ? "1. Answer the question about the plan READ-ONLY. Do NOT apply any changes to"
      : "1. Answer the question about the backlog READ-ONLY. Do NOT apply any changes to",
    "   any plan file. `plan-discuss` can apply changes to a plan on request, but",
    "   it must NOT here — this is a question-answering pass only. Leave every task",
    "   file exactly as it is.",
    "2. Work fully autonomously. Do NOT ask the user any questions — there is no",
    scoped
      ? "   interactive UI to answer them. Research the codebase and the plan as"
      : "   interactive UI to answer them. Research the codebase and the plans as",
    "   needed to answer accurately.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * Build the prompt for a follow-up `discuss` turn, sent into a resumed session.
 * The session already holds the `/plan-discuss` context from the first turn, so
 * this carries only the new question plus the same read-only / no-questions
 * constraints, which are restated every turn so they cannot drift.
 *
 * #110: mirrors buildDiscussPrompt's optional scoping. When `taskId` is non-empty
 * the follow-up is framed as being about that single task; when empty it is a
 * whole-project / backlog follow-up — the identical read-only + no-questions
 * reminders apply either way.
 */
function buildDiscussFollowUpPrompt(taskId: string, question: string): string {
  return [
    taskId.length > 0
      ? `Follow-up question about plans-cc task ${taskId}:`
      : `Follow-up question about this project's plans-cc backlog:`,
    "",
    `"""`,
    question,
    `"""`,
    "",
    "Reminder: answer READ-ONLY. Do NOT apply any changes to any plan file or",
    "any other file. Work fully autonomously and do NOT ask the user any",
    "questions — there is no interactive UI to answer them.",
  ].join("\n");
}

/**
 * APPLY-enabled variant of `buildDiscussPrompt` (#114). Used for a PER-PLAN
 * discuss turn launched with `--apply`: instead of forbidding edits, it tells
 * the agent it MAY apply the agreed change to THIS plan's file via
 * `plan-discuss` when the user's message asks for it. Everything else matches
 * the read-only prompt — the run is still unattended, so the agent works fully
 * autonomously and asks no questions.
 *
 * Scoped to a single task only: the apply feature is per-plan, so `taskId` is
 * always non-empty here (the whole-project/backlog discuss never applies).
 */
function buildApplyDiscussPrompt(taskId: string, description: string): string {
  return [
    `Use the \`plan-discuss\` skill to discuss the plans-cc task with id ${taskId}:`,
    "",
    `/plan-discuss ${taskId}`,
    "",
    `The user has sent the following message about this plan — respond to it:`,
    "",
    `"""`,
    description,
    `"""`,
    "",
    "Requirements:",
    "1. If (and only if) the user's message asks you to change this plan, you MAY",
    "   apply the agreed change to THIS plan's file via `plan-discuss`. If the",
    "   message is only a question, answer it and leave the plan file untouched —",
    "   do not make edits that were not requested. Only ever touch this single",
    `   plan's file (task ${taskId}); never any other task's file.`,
    "2. Work fully autonomously. Do NOT ask the user any questions — there is no",
    "   interactive UI to answer them. Research the codebase and the plan as",
    "   needed, then apply the change or answer as appropriate.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

/**
 * APPLY-enabled variant of `buildDiscussFollowUpPrompt` (#114), sent into a
 * resumed session for a per-plan apply discuss. The session already holds the
 * `/plan-discuss` context; this carries the new message plus the same
 * may-apply / no-questions constraints, restated every turn so they can't
 * drift. Per-plan only, so `taskId` is always non-empty.
 */
function buildApplyDiscussFollowUpPrompt(taskId: string, question: string): string {
  return [
    `Follow-up message about plans-cc task ${taskId}:`,
    "",
    `"""`,
    question,
    `"""`,
    "",
    "Reminder: if the message asks you to change this plan, you MAY apply the",
    `agreed change to THIS plan's file (task ${taskId}) via \`plan-discuss\`;`,
    "otherwise just answer and leave the plan untouched. Never touch any other",
    "task's file. Work fully autonomously and do NOT ask the user any questions —",
    "there is no interactive UI to answer them.",
  ].join("\n");
}

/**
 * Build the prompt for a `review` run (#083). This is a GUIDED, interactive
 * review: the `plan-review` skill walks the task's observations with the user,
 * asking via `AskUserQuestion` — which `canUseTool` parks and the Swift app
 * answers over stdin. Unlike every other mode the prompt is deliberately a BARE
 * slash command (no autonomous "do not ask" trailer): the whole point is to let
 * the skill ask. Any trailing prose would be consumed by the skill as
 * `$ARGUMENTS`, so behavioral rules live in `buildReviewSystemPrompt` instead.
 *
 * Only the `worktree` location may contain the word "worktree": the skill
 * keyword-matches its third argument. `kept` and `main` therefore send a plain
 * `/plan-review NNN` (the kept-worktree path is supplied to the skill out of
 * band by the caller's working directory), while `worktree` sends
 * `/plan-review NNN worktree`.
 */
function buildReviewPrompt(taskId: string, location: ReviewLocation): string {
  if (location === "worktree") {
    return `/plan-review ${taskId} worktree`;
  }
  return `/plan-review ${taskId}`;
}

/**
 * The behavioral rules for a `review` run (#083), carried as a SEPARATE
 * `systemPrompt` (never in the prompt, which would be consumed as `$ARGUMENTS`).
 * The one load-bearing rule: when the user picks "Something's wrong" in the
 * skill's per-observation loop, their free-text explanation arrives as the
 * AskUserQuestion answer, so the skill's "Something's wrong" branch must act on
 * that text rather than discarding it.
 */
function buildReviewSystemPrompt(): string {
  return [
    "You are driving an INTERACTIVE guided plan review via the `plan-review`",
    "skill. The user is present and answering your questions through the",
    "AskUserQuestion tool, so DO ask them — never assume answers or run",
    "autonomously past a decision point.",
    "",
    "In the per-observation loop, when the user chooses \"Something's wrong\",",
    "their free-text description of what is wrong is delivered as the answer to",
    "that AskUserQuestion. Treat that text as the content of the \"Something's",
    "wrong\" branch: route it into the skill's follow-up so the problem the user",
    "described is what gets acted on. Never drop or ignore that free text.",
  ].join("\n");
}

/**
 * Reads the task's `**Worktree:**` path from its `.plans` file for a `kept`
 * review (#083). plans-cc writes the live worktree path on a kept-worktree task;
 * the guided review must `cd` into it, so we resolve it up front. Searches the
 * `review` folder first (kept worktrees only meaningfully exist on review-state
 * tasks), then the other status folders as a fallback. Returns the trimmed path
 * when present and non-empty, else `undefined`.
 */
function readTaskWorktreePath(
  projectRoot: string,
  taskId: string,
): string | undefined {
  try {
    const folders = ["review", "pending", "completed"];
    for (const folder of folders) {
      const dir = path.join(projectRoot, ".plans", folder);
      let entries: string[];
      try {
        entries = fs.readdirSync(dir);
      } catch {
        continue;
      }
      const match = entries.find(
        (name) => name.startsWith(`${taskId}-`) && name.endsWith(".md"),
      );
      if (!match) {
        continue;
      }
      const contents = fs.readFileSync(path.join(dir, match), "utf8");
      const m = contents.match(/^\*\*Worktree:\*\*\s*(.+?)\s*$/im);
      if (m) {
        const value = m[1].trim();
        if (value.length > 0) {
          return value;
        }
      }
    }
  } catch {
    // Any unexpected failure: treat the path as missing so the caller's guard
    // fires rather than silently falling through to a bad checkout.
  }
  return undefined;
}

function buildPrompt(args: Args): string {
  if (args.mode === "capture") {
    return buildCapturePrompt(args.description ?? "");
  }
  if (args.mode === "captureElaborate") {
    return buildCaptureElaboratePrompt(args.description ?? "", args.deep ?? false);
  }
  if (args.mode === "executeYolo") {
    return buildExecuteYoloPrompt(args.description ?? "", args.keep ?? false);
  }
  if (args.mode === "reElaborate") {
    return buildReElaboratePrompt(
      args.taskId ?? "",
      args.description ?? "",
      args.deep ?? false,
    );
  }
  if (args.mode === "reElaborateReview") {
    return buildReviewReElaboratePrompt(
      args.taskId ?? "",
      args.deep ?? false,
      args.description,
    );
  }
  if (args.mode === "elaborate") {
    return buildElaboratePrompt(
      args.taskId ?? "",
      args.deep ?? false,
      args.description,
    );
  }
  if (args.mode === "review") {
    return buildReviewPrompt(args.taskId ?? "", args.reviewLocation ?? "main");
  }
  if (args.mode === "delete") {
    return buildDeletePrompt(args.taskId ?? "");
  }
  if (args.mode === "backlog") {
    return buildBacklogPrompt(args.taskId ?? "");
  }
  if (args.mode === "restore") {
    return buildRestorePrompt(args.taskId ?? "");
  }
  if (args.mode === "discuss") {
    // #114: an apply-enabled per-plan discuss swaps the read-only prompt for one
    // that PERMITS applying the agreed change, honoring the same resume/first-turn
    // split as the read-only branch. The default (non-apply) discuss is unchanged.
    if (args.apply) {
      if (args.resume) {
        return buildApplyDiscussFollowUpPrompt(args.taskId ?? "", args.description ?? "");
      }
      return buildApplyDiscussPrompt(args.taskId ?? "", args.description ?? "");
    }
    if (args.resume) {
      return buildDiscussFollowUpPrompt(args.taskId ?? "", args.description ?? "");
    }
    return buildDiscussPrompt(args.taskId ?? "", args.description ?? "");
  }
  return buildExecutePrompt(
    args.taskId ?? "",
    args.keep ?? false,
    args.deep ?? false,
    args.description,
  );
}

/**
 * Reads the current `**Status:**` of an execute task from its `.plans` file.
 *
 * Boundary-bug guard (task #058): an `execute` run streams its SDK `result`
 * and we faithfully report `done` — but `plan-execute` can stop one layer too
 * early and leave the task frozen at `in-progress` instead of advancing it to
 * `review`. Reporting a clean success then masks a stranded task. So after the
 * result arrives we re-read the task's status from disk to confirm it reached a
 * terminal state.
 *
 * Searches the three status folders (`pending`, `review`, `completed`) for a
 * file matching `${taskId}-*.md`. Returns the lowercased status string, or
 * `undefined` if the file cannot be found or read — in that case the caller
 * MUST NOT emit the stranded signal (a false positive masking a real success is
 * worse than a missed strand).
 */
function readTaskStatus(
  projectRoot: string,
  taskId: string,
): string | undefined {
  try {
    const folders = ["pending", "review", "completed"];
    for (const folder of folders) {
      const dir = path.join(projectRoot, ".plans", folder);
      let entries: string[];
      try {
        entries = fs.readdirSync(dir);
      } catch {
        continue;
      }
      const match = entries.find(
        (name) => name.startsWith(`${taskId}-`) && name.endsWith(".md"),
      );
      if (!match) {
        continue;
      }
      const contents = fs.readFileSync(path.join(dir, match), "utf8");
      const m = contents.match(/^\*\*Status:\*\*\s*([a-z-]+)/im);
      if (m) {
        return m[1].toLowerCase();
      }
    }
  } catch {
    // Any unexpected failure: treat status as unknown so we never emit a false
    // stranded signal.
  }
  return undefined;
}

/** Terminal states an execute task must reach so the run counts as finished. */
const TERMINAL_TASK_STATUSES = new Set(["review", "in-review"]);

/**
 * The set of task ids currently present in the project's `.plans/` directory
 * (task #100). Scans the same three status folders `readTaskStatus` does
 * (`pending`, `review`, `completed`) and parses the leading `NNN-` id from each
 * `*.md` filename (plans-cc names task files `<id>-<slug>.md`). Ids are kept as
 * raw strings so they compare byte-for-byte against the Swift baseline (which is
 * also string-keyed), covering 3-digit AND 4-digit ids alike.
 *
 * Used by the NEW-TASK modes (`captureElaborate` / `executeYolo`) to detect the
 * single task id that THIS run created, so the launcher can report it
 * authoritatively via a `captured` event instead of leaving the Swift side to
 * infer it from an ambiguous baseline diff. Guarded in try/catch like
 * `readTaskStatus`: any read failure returns the ids found so far (possibly
 * empty), so a filesystem hiccup can NEVER crash the run — it just means no
 * diff this scan, and Swift's baseline-diff fallback still applies.
 */
function readPlansTaskIDs(projectRoot: string): Set<string> {
  const ids = new Set<string>();
  try {
    const folders = ["pending", "review", "completed"];
    for (const folder of folders) {
      const dir = path.join(projectRoot, ".plans", folder);
      let entries: string[];
      try {
        entries = fs.readdirSync(dir);
      } catch {
        continue;
      }
      for (const name of entries) {
        if (!name.endsWith(".md")) {
          continue;
        }
        // Leading digit run before the first `-` (e.g. `098-foo.md` → `098`).
        const m = name.match(/^(\d+)-/);
        if (m) {
          ids.add(m[1]);
        }
      }
    }
  } catch {
    // Any unexpected failure: return whatever was gathered so far. Never throw.
  }
  return ids;
}

/**
 * Built-in, always-on tool allowlist (task #092 refactor). Includes the Skill
 * tool (so the agent can invoke the plan-* skills this hand-off drives — without
 * it on the allowlist, the Skill invocation is denied and the agent flails), the
 * Agent (subagent) tool, plus the tools the skills need to do real work.
 *
 * This is the SAFE DEFAULT: it is always applied, and user config may only
 * EXTEND it (never remove an entry), so no guardrail can be turned off from
 * `.plans/config.json`.
 */
const BASE_ALLOWED_TOOLS: string[] = [
  "Skill",
  "Agent",
  "Task",
  "Read",
  "Write",
  "Edit",
  "Bash",
  "Glob",
  "Grep",
  "TodoWrite",
  // Read-only Figma verification tools. des-build's self-verification
  // visual diff was hard-denied under `permissionMode: "acceptEdits"`
  // because MCP tools are not auto-approved and these weren't
  // allowlisted (task #051 root cause), which stranded the run. That
  // fix allowlisted only screenshot + metadata, so des-build still
  // cleared its get_metadata preflight and then aborted mid-build at
  // Step 5 when it reached get_design_context. These three are the
  // complete set des-build declares in its frontmatter, and all three
  // are READ-ONLY, so they are safe to allow. Do NOT add any Figma
  // write/edit tools here.
  "mcp__figma-dev-mode-mcp-server__get_screenshot",
  "mcp__figma-dev-mode-mcp-server__get_metadata",
  "mcp__figma-dev-mode-mcp-server__get_design_context",
  // Playwright tools for rendered-page verification. These six are the
  // exact set plans-cc's plan-execute (visual-comparison stage) and
  // des-build (`verify <url>`) declare in their frontmatter. Without
  // them, `permissionMode: "acceptEdits"` denies them and the stage
  // reports "Visual comparison NOT run: Playwright MCP unavailable".
  // Add only these. Do NOT add interactive Playwright tools (click,
  // type, fill_form, run_code_unsafe, etc.).
  "mcp__playwright__browser_navigate",
  "mcp__playwright__browser_resize",
  "mcp__playwright__browser_take_screenshot",
  "mcp__playwright__browser_evaluate",
  "mcp__playwright__browser_snapshot",
  "mcp__playwright__browser_wait_for",
  // Read-only Sentry tools (task #092). Under
  // `permissionMode: "acceptEdits"` MCP tools are not auto-approved, so
  // a headless capture/elaborate run that reaches for Sentry was
  // hard-denied ("haven't granted it yet") and the agent flailed. These
  // are the Sentry query/inspection tools — all READ-ONLY, so they are
  // safe to allow unattended. Write tools (specifically
  // `mcp__sentry__update_issue`) are deliberately EXCLUDED so an
  // unattended run can never mutate Sentry issues. Keep this list narrow
  // and tool-by-tool — do NOT add a `mcp__sentry__*` wildcard, which
  // would pull in the write/mutation tools too.
  "mcp__sentry__get_sentry_resource",
  "mcp__sentry__search_issues",
  "mcp__sentry__search_errors",
  "mcp__sentry__search_events",
  "mcp__sentry__search_traces",
  "mcp__sentry__search_logs",
  "mcp__sentry__analyze_issue_with_seer",
  "mcp__sentry__find_organizations",
  "mcp__sentry__find_projects",
];

/**
 * Tool allowlist for `discuss` runs. Discussion is strictly read-only, so it
 * gets only the Skill tool (to load `plan-discuss`) plus the read-only file
 * tools. This REPLACES the base allowlist and is NOT extended by the project's
 * `extraAllowedTools`, so config can never re-enable a write tool for discuss.
 */
const DISCUSS_ALLOWED_TOOLS: string[] = ["Skill", "Read", "Glob", "Grep"];

/**
 * Tools explicitly denied for `discuss` runs. `acceptEdits` would otherwise
 * auto-approve file edits, so the write-capable tools are hard-blocked rather
 * than relying on the prompt's read-only instruction.
 */
const DISCUSS_DISALLOWED_TOOLS: string[] = [
  "Write",
  "Edit",
  "NotebookEdit",
  "Bash",
];

/**
 * Read an OPTIONAL per-project extra-allowed-tools list from
 * `<projectRoot>/.plans/config.json` under the `extraAllowedTools` key (task
 * #092). The value must be an array of strings; anything else is ignored.
 *
 * This can only EXTEND the built-in allowlist — it is concatenated onto
 * `BASE_ALLOWED_TOOLS` by the caller, never used to remove an entry. Returns
 * `[]` on ANY failure (file missing, unparseable JSON, key absent, or value not
 * a string array) and NEVER throws, so a malformed config can never strand a
 * run.
 */
function readExtraAllowedTools(projectRoot: string): string[] {
  try {
    const configPath = path.join(projectRoot, ".plans", "config.json");
    const raw = fs.readFileSync(configPath, "utf8");
    const parsed = JSON.parse(raw);
    const extra = parsed?.extraAllowedTools;
    if (
      Array.isArray(extra) &&
      extra.every((t) => typeof t === "string")
    ) {
      return extra as string[];
    }
  } catch {
    // Missing file, bad JSON, or any other read failure: fall back to the
    // built-in base only. Never throw.
  }
  return [];
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args) {
    emitError(
      "Missing or invalid arguments. Usage: run-task.js --project-root <abs path> [--mode execute|elaborate|reElaborate|capture|captureElaborate|executeYolo|delete|backlog|restore|discuss] (--task-id <NNN> for execute/elaborate/delete/backlog/restore; --description <text> for capture/captureElaborate/executeYolo; BOTH --task-id <NNN> and --description <text> for reElaborate; --description <text> for discuss with --task-id OPTIONAL (omit it for a whole-project discussion); optional --resume <session id> for discuss only)",
    );
    process.exit(1);
    return;
  }

  // #083: a `kept` review must inspect the task's kept execution worktree. Read
  // that path up front; if it is missing or not on disk, the review cannot
  // proceed — fail loudly rather than falling through to a bad checkout. This
  // guard is kept-only: `worktree`/`main` resolve their checkout themselves.
  let reviewCwd = args.projectRoot;
  if (args.mode === "review" && args.reviewLocation === "kept") {
    const worktree = readTaskWorktreePath(args.projectRoot, args.taskId ?? "");
    if (!worktree || !fs.existsSync(worktree)) {
      emitError(
        `Kept worktree for task ${args.taskId} not found. Expected the task's `
          + `**Worktree:** path to exist on disk; re-run with a different review `
          + `location, or restore the kept worktree.`,
      );
      process.exit(1);
      return;
    }
    reviewCwd = worktree;
  }

  try {
    // Combine the built-in safe-default allowlist with any per-project
    // extensions from `.plans/config.json` (`extraAllowedTools`). Config may
    // only EXTEND — the base is always present — and we dedupe so a repeated
    // entry doesn't appear twice.
    // Discuss is the exception: it uses its own fixed read-only allowlist and
    // ignores the config extensions entirely.
    // #114: an APPLY-enabled per-plan discuss (`isApplyDiscuss`) is the one
    // discuss variant that is write-capable — it reuses the SAME base+extra
    // allowlist as the non-discuss lifecycle path (which already includes the
    // write tools and `Skill`) and applies NO disallowed block, so the agent can
    // edit this plan's file via `plan-discuss`. The DEFAULT (read-only) discuss
    // branch below is left byte-for-byte unchanged.
    const isDiscuss = args.mode === "discuss";
    const isApplyDiscuss = isDiscuss && !!args.apply;
    // #083: review is the only mode with a parked, user-answered permission
    // callback. A BARE allowlist entry SHADOWS/bypasses `canUseTool` (the SDK
    // logs `[CLAUDE_SDK_CAN_USE_TOOL_SHADOWED]`), so `AskUserQuestion` MUST be
    // stripped from the merged allowlist for the callback to fire. Never set
    // `canUseTool` for any other mode — an autonomous verb must never park.
    const isReview = args.mode === "review";
    const baseExtraAllowed = Array.from(
      new Set([
        ...BASE_ALLOWED_TOOLS,
        ...readExtraAllowedTools(args.projectRoot),
      ]),
    ).filter((t) => !(isReview && t === "AskUserQuestion"));
    const allowedTools =
      isDiscuss && !isApplyDiscuss ? DISCUSS_ALLOWED_TOOLS : baseExtraAllowed;

    // #083: the parked-question bridge. `canUseTool` emits the question, parks a
    // Promise keyed by the SDK's `toolUseID`, and the stdin reader resolves it
    // from the Swift app's `{kind:"answer",toolUseId,answers}` line. Active ONLY
    // in review mode; never installed otherwise.
    const pendingQuestions = new Map<
      string,
      (answers: Record<string, string>) => void
    >();
    const cancelPendingQuestions = (): void => {
      for (const resolve of pendingQuestions.values()) {
        // Resolve with an empty answer so a parked Promise can settle and node
        // can exit on EOF/abort rather than hanging forever.
        resolve({});
      }
      pendingQuestions.clear();
    };

    let reviewStdinBuffer = "";
    const onStdinChunk = (chunk: Buffer): void => {
      reviewStdinBuffer += chunk.toString("utf8");
      let nl: number;
      while ((nl = reviewStdinBuffer.indexOf("\n")) >= 0) {
        const line = reviewStdinBuffer.slice(0, nl).trim();
        reviewStdinBuffer = reviewStdinBuffer.slice(nl + 1);
        if (line.length === 0) {
          continue;
        }
        try {
          const parsed = JSON.parse(line);
          if (
            parsed &&
            parsed.kind === "answer" &&
            typeof parsed.toolUseId === "string"
          ) {
            const resolve = pendingQuestions.get(parsed.toolUseId);
            if (resolve) {
              pendingQuestions.delete(parsed.toolUseId);
              const answers =
                parsed.answers && typeof parsed.answers === "object"
                  ? (parsed.answers as Record<string, string>)
                  : {};
              resolve(answers);
            }
          }
        } catch {
          // Ignore malformed stdin lines — a stray line must never crash the run.
        }
      }
    };
    if (isReview) {
      process.stdin.on("data", onStdinChunk);
      process.stdin.on("end", cancelPendingQuestions);
      process.stdin.resume();
    }

    const response = query({
      prompt: buildPrompt(args),
      options: {
        cwd: reviewCwd,
        permissionMode: "acceptEdits",
        maxBudgetUsd: isDiscuss ? DISCUSS_MAX_BUDGET_USD : MAX_BUDGET_USD,
        allowedTools,
        ...(isReview ? { systemPrompt: buildReviewSystemPrompt() } : {}),
        ...(isReview
          ? {
              canUseTool: async (
                toolName: string,
                input: Record<string, unknown>,
                options: { toolUseID?: string; signal?: AbortSignal },
              ) => {
                const toolUseId = options.toolUseID ?? "";
                if (toolName === "AskUserQuestion") {
                  // Emit the question to the Swift app and park until its answer
                  // (or EOF / abort) arrives. The wire field is `toolUseId`
                  // (lowercase d) even though the SDK option is `toolUseID`.
                  emit({
                    kind: "question",
                    toolUseId,
                    questions: (input as { questions?: unknown }).questions,
                  });
                  const answers = await new Promise<Record<string, string>>(
                    (resolve) => {
                      pendingQuestions.set(toolUseId, resolve);
                      const signal = options.signal;
                      if (signal) {
                        const onAbort = () => {
                          pendingQuestions.delete(toolUseId);
                          resolve({});
                        };
                        if (signal.aborted) {
                          onAbort();
                        } else {
                          signal.addEventListener("abort", onAbort, {
                            once: true,
                          });
                        }
                      }
                    },
                  );
                  return {
                    behavior: "allow" as const,
                    updatedInput: {
                      questions: (input as { questions?: unknown }).questions,
                      answers,
                    },
                  };
                }
                // Any OTHER unlisted tool: deny with the stable marker substring
                // so the existing `denied` tool_result path reports it.
                return {
                  behavior: "deny" as const,
                  message:
                    `Claude requested permission to use ${toolName}, but you `
                      + `haven't granted it yet.`,
                };
              },
            }
          : {}),
        ...(isDiscuss && !isApplyDiscuss
          ? { disallowedTools: DISCUSS_DISALLOWED_TOOLS }
          : {}),
        ...(args.resume ? { resume: args.resume } : {}),
      },
    });

    // Maps a `tool_use` block's id → tool name so a later denied `tool_result`
    // (which carries only the `tool_use_id`, not the name) can be resolved back
    // to the tool the agent tried to call. Task #092.
    const toolUseNames = new Map<string, string>();

    // Task #100: the NEW-TASK modes (`captureElaborate` / `executeYolo`) have no
    // `taskId` at launch — the task does not exist yet — so the created id is
    // reported authoritatively from the launcher rather than inferred by Swift's
    // ambiguous baseline diff. Snapshot the project's existing `.plans` ids BEFORE
    // the stream begins; as the run streams we re-scan and, when EXACTLY one new
    // id has appeared, emit `captured` once. Every other mode leaves this inert.
    const reportsCapturedID =
      args.mode === "captureElaborate" || args.mode === "executeYolo";
    const capturedBaseline = reportsCapturedID
      ? readPlansTaskIDs(args.projectRoot)
      : new Set<string>();
    // One-shot guard: once the created id is emitted we stop scanning, so a later
    // re-scan can never double-emit `captured` for the same run.
    let capturedEmitted = false;

    // Re-scan `.plans` for the single new id and emit `captured` exactly once.
    // Ambiguity (more than one new id in a scan) is left to Swift's baseline-diff
    // fallback — the launcher only speaks when it can name the id unambiguously.
    const maybeEmitCaptured = (): void => {
      if (!reportsCapturedID || capturedEmitted) {
        return;
      }
      const current = readPlansTaskIDs(args.projectRoot);
      const newIds: string[] = [];
      for (const id of current) {
        if (!capturedBaseline.has(id)) {
          newIds.push(id);
        }
      }
      if (newIds.length === 1) {
        capturedEmitted = true;
        emit({ kind: "captured", taskId: newIds[0] });
      }
    };

    for await (const message of response) {
      switch (message.type) {
        case "assistant": {
          const blocks = message.message?.content;
          if (Array.isArray(blocks)) {
            for (const block of blocks) {
              if (block?.type === "tool_use") {
                // Record id → name so a denied tool_result can be named later.
                if (typeof block.id === "string") {
                  toolUseNames.set(block.id, String(block.name ?? "unknown"));
                }
                emit({
                  kind: "activity",
                  tool: String(block.name ?? "unknown"),
                  detail: toolDetail(block.input),
                });
              } else if (block?.type === "text") {
                const chunk = String(block.text ?? "");
                if (chunk.length > 0) {
                  emit({ kind: "text", chunk });
                }
              }
            }
          }
          // Task #100: after each assistant turn (the points at which the agent
          // has just run tools that may have written the new task file), re-scan
          // `.plans` for the created id and report it the moment it appears — so
          // the live spinner hands off to the real plan row mid-run rather than
          // at process exit. No-op after the first emit and for non-new-task modes.
          maybeEmitCaptured();
          break;
        }
        case "result": {
          // `subtype` is "success" or an error discriminator
          // (error_max_turns, error_max_budget_usd, …). Prefer the model's
          // stop_reason when present, otherwise fall back to subtype.
          let stopReason = message.stop_reason ?? message.subtype ?? "unknown";

          // Boundary-bug guard (task #058): for execute runs ONLY, the SDK
          // reporting `result` does NOT prove the task reached a terminal
          // state. `plan-execute` can stop one layer too early and leave the
          // task frozen at `in-progress`, in which case a vanilla success
          // `done` line would mask a stranded task. So when the run otherwise
          // finished cleanly (an end_turn/success stopReason — NOT a
          // budget/turn-cap error, whose truncation reason is more actionable
          // and is already handled downstream), re-read the task's status from
          // disk and, if it never reached `review`/`in-review`, override the
          // stopReason with a distinct `stranded_at_in_progress` signal.
          //
          // capture/elaborate/captureElaborate/executeYolo are excluded: those
          // modes have no single terminal `review` contract here and defer
          // their terminal-state handling to the Swift side.
          //
          // Specifically for the NEW-TASK modes (`captureElaborate` /
          // `executeYolo`): they are intentionally NOT terminal-state checked
          // here because the new task's id is not known at parse time (the task
          // does not yet exist when the launcher starts), so `readTaskStatus`
          // has nothing to look up. Their terminal-state reconciliation is
          // deferred to the Swift `reconcileFinishedCaptures` path (#051/#053),
          // which detects the newly-created task id after `store.reload()` and
          // hands the spinner row off to the real plan row. This deferral is the
          // accepted first-cut fallback for #058 — no launcher-side
          // timestamp-scanning is done for these modes.
          if (
            args.mode === "execute" &&
            args.taskId &&
            !truncatingStopReasons.has(stopReason)
          ) {
            const status = readTaskStatus(args.projectRoot, args.taskId);
            // Only override on a known, non-terminal status. An unknown status
            // (file missing/unreadable) falls through to the normal `done` —
            // never emit a false stranded signal that masks a real success.
            if (status !== undefined && !TERMINAL_TASK_STATUSES.has(status)) {
              stopReason = "stranded_at_in_progress";
            }
          }

          // On success, surface the agent's clean final answer (the `text`
          // chunks above include narration and preambles). Error results carry
          // no `result`, so nothing is emitted for them.
          if (message.subtype === "success") {
            emit({
              kind: "reply",
              text: message.result,
              sessionId: message.session_id,
            });
          }

          emit({
            kind: "done",
            costUsd: message.total_cost_usd ?? 0,
            turns: message.num_turns ?? 0,
            stopReason,
          });
          break;
        }
        case "user": {
          // Tool RESULTS (including permission denials) arrive on `user`-type
          // messages whose content is an array of `tool_result` blocks. When a
          // tool the agent reached for was NOT on the allowlist, the SDK injects
          // a result whose text contains the marker below. We surface that as a
          // distinct, NON-fatal `denied` line (task #092): the run is NOT failed
          // and continues — unlike `error`, which is terminal. We do NOT set
          // the summary/error for a denial.
          const blocks = message.message?.content;
          if (Array.isArray(blocks)) {
            for (const block of blocks) {
              if (block?.type !== "tool_result") {
                continue;
              }
              // A denial is only counted when the tool_result is itself an
              // error (`is_error === true`) AND its flattened text carries the
              // SDK's `Claude requested permissions to use` wording (#116). A
              // SUCCESSFUL read whose content merely mentions that phrase — e.g.
              // a file or log line — is NOT a denial and must not be flagged.
              if (!isPermissionDenial(block)) {
                continue;
              }
              // tool_result carries only the tool_use_id, not the name — map it
              // back via the id→name table; fall back to "unknown".
              const id =
                typeof block.tool_use_id === "string"
                  ? block.tool_use_id
                  : undefined;
              const resolvedName =
                (id && toolUseNames.get(id)) || "unknown";
              emit({ kind: "denied", tool: resolvedName });
            }
          }
          break;
        }
        case "system": {
          // Only the `init` message is part of our contract: it carries the
          // session id a follow-up discuss turn passes back via `--resume`.
          if (message.subtype === "init") {
            emit({ kind: "session", sessionId: message.session_id });
          }
          break;
        }
        default:
          // All other SDK message kinds are intentionally not part of our
          // stable contract.
          break;
      }
    }

    // #083: the message loop ended. Settle any still-parked question and tear
    // down the stdin reader so node actually exits (an open, resumed stdin keeps
    // the event loop alive). No-op for non-review modes, which never attached it.
    if (isReview) {
      cancelPendingQuestions();
      process.stdin.off("data", onStdinChunk);
      process.stdin.off("end", cancelPendingQuestions);
      process.stdin.destroy();
    }
  } catch (err) {
    const message =
      err instanceof Error ? err.message : String(err ?? "unknown error");
    emitError(message);
    process.exit(1);
  }
}

// Only launch a run when this module is executed as the entry script. When it
// is imported (e.g. by the denial-predicate test), `main()` must NOT fire.
const isEntry =
  !!process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntry) {
  main().catch((err) => {
    const message =
      err instanceof Error ? err.message : String(err ?? "unknown error");
    emitError(message);
    process.exit(1);
  });
}
