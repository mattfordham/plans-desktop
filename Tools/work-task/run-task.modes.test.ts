/**
 * Argument parsing and prompt shape for the interactive `complete` mode.
 *
 * Run via Node's built-in TypeScript type-stripping (Node >= 22.6):
 *   node --test run-task.modes.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseArgs, buildPrompt, isInteractiveMode } from "./run-task.ts";

test("complete mode parses with a task id and no description", () => {
  const args = parseArgs(["--project-root", "/p", "--task-id", "083", "--mode", "complete"]);
  assert.ok(args);
  assert.equal(args.mode, "complete");
  assert.equal(args.taskId, "083");
  assert.equal(args.description, undefined);
});

test("complete mode without a task id is rejected", () => {
  assert.equal(parseArgs(["--project-root", "/p", "--mode", "complete"]), null);
});

test("complete mode rejects --resume", () => {
  assert.equal(
    parseArgs(["--project-root", "/p", "--task-id", "1", "--mode", "complete", "--resume", "s"]),
    null,
  );
});

test("complete prompt is a bare slash command (a trailer would become skill arguments)", () => {
  const args = parseArgs(["--project-root", "/p", "--task-id", "083", "--mode", "complete"]);
  assert.ok(args);
  assert.equal(buildPrompt(args), "/plan-complete 083");
});

test("only review and complete are interactive", () => {
  assert.equal(isInteractiveMode("review"), true);
  assert.equal(isInteractiveMode("complete"), true);
  for (const mode of ["execute", "elaborate", "delete", "backlog", "restore", "discuss", "capture"] as const) {
    assert.equal(isInteractiveMode(mode), false, mode);
  }
});
