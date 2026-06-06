/**
 * work-task: Agent SDK hand-off.
 *
 * Autonomously works a single plans-cc task via the Claude Agent SDK. The
 * `--mode` flag selects which skill drives the run:
 *   - `execute`  (default): drives `plan-execute` to implement the task,
 *                always in `worktree` isolation, leaving it in `review`.
 *   - `elaborate`: drives `plan-elaborate` to research/flesh out a pending
 *                task autonomously (no interactive prompts).
 *   - `capture`: drives `plan-capture` to record a new task from a free-text
 *                `--description`, leaving it in `pending` (no chaining).
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

// Hard ceiling on spend. Under subscription (claude login) auth the real bound
// is the plan; this ceiling is the safety net for API-key fallback.
const MAX_BUDGET_USD = 5.0;

/** What the spawned agent should do with the task. */
type Mode = "execute" | "elaborate" | "capture";

interface Args {
  projectRoot: string;
  /** Required for execute/elaborate; undefined for capture (no task exists yet). */
  taskId?: string;
  mode: Mode;
  /** Required for capture: the free-text description to capture as a new task. */
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
        value !== "capture"
      ) {
        return null;
      }
      mode = value;
    }
  }

  if (!projectRoot) {
    return null;
  }

  if (mode === "capture") {
    // Capture creates a brand-new task, so there is no task id yet; a
    // free-text description is required instead.
    if (!description) {
      return null;
    }
    return { projectRoot, mode, description };
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

function buildPrompt(args: Args): string {
  if (args.mode === "capture") {
    return buildCapturePrompt(args.description ?? "");
  }
  if (args.mode === "elaborate") {
    return buildElaboratePrompt(args.taskId ?? "");
  }
  return buildExecutePrompt(args.taskId ?? "");
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args) {
    emitError(
      "Missing or invalid arguments. Usage: run-task.js --project-root <abs path> [--mode execute|elaborate|capture] (--task-id <NNN> for execute/elaborate; --description <text> for capture)",
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
        // Include the Agent (subagent) tool plus the tools the plan-execute
        // skill needs to do real work. Skills are enabled automatically by the
        // SDK; we do not need to list "Skill" here.
        allowedTools: [
          "Agent",
          "Task",
          "Read",
          "Write",
          "Edit",
          "Bash",
          "Glob",
          "Grep",
          "TodoWrite",
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
          emit({
            kind: "done",
            costUsd: message.total_cost_usd ?? 0,
            turns: message.num_turns ?? 0,
            stopReason: message.stop_reason ?? message.subtype ?? "unknown",
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
