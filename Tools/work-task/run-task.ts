/**
 * work-task: Agent SDK hand-off.
 *
 * Autonomously works a single plans-cc task via the Claude Agent SDK. The
 * `--mode` flag selects which skill drives the run:
 *   - `execute`  (default): drives `plan-execute` to implement the task,
 *                always in `worktree` isolation, leaving it in `review`.
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
 *   {"kind":"done","costUsd":N,"turns":N,"stopReason":"…"}
 *   {"kind":"error","message":"…"}
 * Raw SDK message shapes are never emitted; they are mapped to the above.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import * as fs from "node:fs";
import * as path from "node:path";

// Hard ceiling on spend. Under subscription (claude login) auth the real bound
// is the plan; this ceiling is the safety net for API-key fallback. Raised to
// $40 so a single autonomous execute run is far less likely to hit the cap
// mid-task and strand the task at in-progress before it reaches review.
const MAX_BUDGET_USD = 40.0;

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
  | "capture"
  | "captureElaborate"
  | "executeYolo"
  | "delete"
  | "backlog"
  | "restore";

interface Args {
  projectRoot: string;
  /** Required for execute/elaborate/reElaborate/delete; undefined for capture/captureElaborate/executeYolo (no task exists yet). */
  taskId?: string;
  mode: Mode;
  /**
   * The free-text description/guidance to act on. Required for
   * capture/captureElaborate/executeYolo AND reElaborate; OPTIONAL for
   * elaborate (folded into the prompt as user guidance when present).
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

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--project-root") {
      projectRoot = argv[++i];
    } else if (arg === "--task-id") {
      taskId = argv[++i];
    } else if (arg === "--description") {
      description = argv[++i];
    } else if (arg === "--deep") {
      // Valueless flag — do NOT consume the following argv token.
      deep = true;
    } else if (arg === "--keep") {
      // Valueless flag — do NOT consume the following argv token.
      keep = true;
    } else if (arg === "--mode") {
      const value = argv[++i];
      if (
        value !== "execute" &&
        value !== "elaborate" &&
        value !== "reElaborate" &&
        value !== "capture" &&
        value !== "captureElaborate" &&
        value !== "executeYolo" &&
        value !== "delete" &&
        value !== "backlog" &&
        value !== "restore"
      ) {
        return null;
      }
      mode = value;
    }
  }

  if (!projectRoot) {
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
    // reElaborate operates on an EXISTING task AND carries free-text guidance:
    // it is the only mode that requires both a task id and a description.
    if (!taskId || !description) {
      return null;
    }
    return { projectRoot, taskId, mode, description, deep, keep };
  }

  // execute / elaborate / delete / backlog / restore operate on an existing
  // task, so a task id is the only REQUIRED argument. elaborate additionally
  // accepts an OPTIONAL `--description` (the user's guidance for the pass); it
  // is folded in when present and simply absent otherwise, so a bare `--mode
  // elaborate --task-id <id>` behaves exactly as before. execute / delete /
  // backlog / restore carry no free text at all.
  if (!taskId) {
    return null;
  }
  if (mode === "elaborate") {
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
 * Build the prompt for an `execute` run. Worktree isolation is mandatory: the
 * skill is invoked as `/plan-execute <id> worktree` so it can never fall back to
 * editing the main checkout in place — the Plans app only ever hands tasks off
 * for isolated execution.
 *
 * #078: when `keep` is true, a trailing ` keep` token is appended to the
 * `/plan-execute <id> worktree` command line so the worktree is kept after the
 * run rather than cleaned up.
 */
function buildExecutePrompt(taskId: string, keep: boolean): string {
  return [
    `Use the \`plan-execute\` skill to work the plans-cc task with id ${taskId}.`,
    `Invoke it in worktree mode: \`/plan-execute ${taskId} worktree${keep ? " keep" : ""}\`.`,
    "",
    "Requirements:",
    `1. The run MUST use a dedicated git worktree for task ${taskId} (the`,
    "   `worktree` argument above). Never edit the main checkout in place —",
    "   worktree isolation is mandatory for this hand-off.",
    "2. Implement the task fully, following the plan and the repository's",
    "   conventions (including TDD where a test suite exists).",
    "3. Run the targeted tests relevant to your changes and make them pass.",
    "4. When the work is complete and tests pass, move the task to the `review`",
    "   state. Do NOT mark it done — leave it in review for human verification.",
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
  if (args.mode === "elaborate") {
    return buildElaboratePrompt(
      args.taskId ?? "",
      args.deep ?? false,
      args.description,
    );
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
  return buildExecutePrompt(args.taskId ?? "", args.keep ?? false);
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

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args) {
    emitError(
      "Missing or invalid arguments. Usage: run-task.js --project-root <abs path> [--mode execute|elaborate|reElaborate|capture|captureElaborate|executeYolo|delete] (--task-id <NNN> for execute/elaborate/delete; --description <text> for capture/captureElaborate/executeYolo; BOTH --task-id <NNN> and --description <text> for reElaborate)",
    );
    process.exit(1);
    return;
  }

  try {
    const response = query({
      prompt: buildPrompt(args),
      options: {
        cwd: args.projectRoot,
        permissionMode: "acceptEdits",
        maxBudgetUsd: MAX_BUDGET_USD,
        // Include the Skill tool (so the agent can invoke the plan-* skills this
        // hand-off drives — without it on the allowlist, the Skill invocation is
        // denied and the agent flails), the Agent (subagent) tool, plus the
        // tools the skills need to do real work.
        allowedTools: [
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
        ],
      },
    });

    for await (const message of response) {
      switch (message.type) {
        case "assistant": {
          const blocks = message.message?.content;
          if (Array.isArray(blocks)) {
            for (const block of blocks) {
              if (block?.type === "tool_use") {
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

          emit({
            kind: "done",
            costUsd: message.total_cost_usd ?? 0,
            turns: message.num_turns ?? 0,
            stopReason,
          });
          break;
        }
        default:
          // All other SDK message kinds are intentionally not part of our
          // stable contract.
          break;
      }
    }
  } catch (err) {
    const message =
      err instanceof Error ? err.message : String(err ?? "unknown error");
    emitError(message);
    process.exit(1);
  }
}

main().catch((err) => {
  const message =
    err instanceof Error ? err.message : String(err ?? "unknown error");
  emitError(message);
  process.exit(1);
});
