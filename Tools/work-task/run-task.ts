/**
 * work-task: Agent SDK hand-off.
 *
 * Autonomously works a single plans-cc task via the Claude Agent SDK. The
 * `--mode` flag selects which skill drives the run:
 *   - `execute`  (default): drives `plan-execute` to implement the task,
 *                always in `worktree` isolation, leaving it in `review`.
 *   - `elaborate`: drives `plan-elaborate` to research/flesh out a pending
 *                task autonomously (no interactive prompts).
 *   - `reElaborate`: drives `plan-elaborate` (Path C, further elaboration) on an
 *                already-elaborated task, folding in user-provided `--description`
 *                guidance to refine/add to the plan, leaving it `elaborated`. This
 *                is the only mode that needs BOTH `--task-id` AND `--description`.
 *   - `capture`: drives `plan-capture` to record a new task from a free-text
 *                `--description`, leaving it in `pending` (no chaining).
 *   - `captureElaborate`: drives `plan-capture` then chains into
 *                `plan-elaborate` to record AND flesh out a new task from a
 *                free-text `--description`, leaving it in `elaborated` (it does
 *                NOT execute).
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
// $20 so a single autonomous execute run is far less likely to hit the cap
// mid-task and strand the task at in-progress before it reaches review.
const MAX_BUDGET_USD = 20.0;

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
  | "executeYolo";

interface Args {
  projectRoot: string;
  /** Required for execute/elaborate/reElaborate; undefined for capture/captureElaborate/executeYolo (no task exists yet). */
  taskId?: string;
  mode: Mode;
  /** Required for capture/captureElaborate/executeYolo AND reElaborate: the free-text description/guidance to act on. */
  description?: string;
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

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--project-root") {
      projectRoot = argv[++i];
    } else if (arg === "--task-id") {
      taskId = argv[++i];
    } else if (arg === "--description") {
      description = argv[++i];
    } else if (arg === "--mode") {
      const value = argv[++i];
      if (
        value !== "execute" &&
        value !== "elaborate" &&
        value !== "reElaborate" &&
        value !== "capture" &&
        value !== "captureElaborate" &&
        value !== "executeYolo"
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
    return { projectRoot, mode, description };
  }

  if (mode === "reElaborate") {
    // reElaborate operates on an EXISTING task AND carries free-text guidance:
    // it is the only mode that requires both a task id and a description.
    if (!taskId || !description) {
      return null;
    }
    return { projectRoot, taskId, mode, description };
  }

  // execute / elaborate operate on an existing task.
  if (!taskId) {
    return null;
  }
  return { projectRoot, taskId, mode };
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
 */
function buildExecutePrompt(taskId: string): string {
  return [
    `Use the \`plan-execute\` skill to work the plans-cc task with id ${taskId}.`,
    `Invoke it in worktree mode: \`/plan-execute ${taskId} worktree\`.`,
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
 */
function buildElaboratePrompt(taskId: string): string {
  return [
    `Use the \`plan-elaborate\` skill to research and flesh out the plans-cc`,
    `task with id ${taskId}.`,
    "",
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
function buildReElaboratePrompt(taskId: string, description: string): string {
  return [
    `Use the \`plan-elaborate\` skill to FURTHER elaborate (Path C) the existing,`,
    `already-elaborated plans-cc task with id ${taskId}:`,
    "",
    `/plan-elaborate ${taskId}`,
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
function buildCaptureElaboratePrompt(description: string): string {
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
    `   /plan-elaborate <new-id>`,
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
 */
function buildExecuteYoloPrompt(description: string): string {
  return [
    `Use the \`plan-execute\` skill to autonomously work a brand-new plans-cc`,
    `task captured from the following description, in yolo mode:`,
    "",
    `/plan-execute "${description}" yolo`,
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

function buildPrompt(args: Args): string {
  if (args.mode === "capture") {
    return buildCapturePrompt(args.description ?? "");
  }
  if (args.mode === "captureElaborate") {
    return buildCaptureElaboratePrompt(args.description ?? "");
  }
  if (args.mode === "executeYolo") {
    return buildExecuteYoloPrompt(args.description ?? "");
  }
  if (args.mode === "reElaborate") {
    return buildReElaboratePrompt(args.taskId ?? "", args.description ?? "");
  }
  if (args.mode === "elaborate") {
    return buildElaboratePrompt(args.taskId ?? "");
  }
  return buildExecutePrompt(args.taskId ?? "");
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
      "Missing or invalid arguments. Usage: run-task.js --project-root <abs path> [--mode execute|elaborate|reElaborate|capture|captureElaborate|executeYolo] (--task-id <NNN> for execute/elaborate; --description <text> for capture/captureElaborate/executeYolo; BOTH --task-id <NNN> and --description <text> for reElaborate)",
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
          // allowlisted (task #051 root cause), which stranded the run. These
          // two are READ-ONLY verification tools (screenshot + metadata), so
          // they are safe to allow. Do NOT add any Figma write/edit tools here.
          "mcp__figma-dev-mode-mcp-server__get_screenshot",
          "mcp__figma-dev-mode-mcp-server__get_metadata",
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
