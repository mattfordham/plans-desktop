/**
 * work-task: Agent SDK hand-off.
 *
 * Autonomously executes a single plans-cc task by driving the `plan-execute`
 * skill via the Claude Agent SDK. This process is the SOLE writer of the
 * project's `.plans/` directory and git tree — the Plans.app itself is a
 * strictly read-only viewer.
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

interface Args {
  projectRoot: string;
  taskId: string;
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

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--project-root") {
      projectRoot = argv[++i];
    } else if (arg === "--task-id") {
      taskId = argv[++i];
    }
  }

  if (!projectRoot || !taskId) {
    return null;
  }
  return { projectRoot, taskId };
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

function buildPrompt(taskId: string): string {
  return [
    `Use the \`plan-execute\` skill to work the plans-cc task with id ${taskId}.`,
    "",
    "Requirements:",
    `1. Create a dedicated git worktree for task ${taskId} so the work is isolated`,
    "   from the main checkout (follow the skill's worktree conventions).",
    "2. Implement the task fully, following the plan and the repository's",
    "   conventions (including TDD where a test suite exists).",
    "3. Run the targeted tests relevant to your changes and make them pass.",
    "4. When the work is complete and tests pass, move the task to the `review`",
    "   state. Do NOT mark it done — leave it in review for human verification.",
    "",
    "Work autonomously to completion. Do not ask for confirmation.",
  ].join("\n");
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args) {
    emitError(
      "Missing required arguments. Usage: run-task.js --project-root <abs path> --task-id <NNN>",
    );
    process.exit(1);
    return;
  }

  try {
    const response = query({
      prompt: buildPrompt(args.taskId),
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
