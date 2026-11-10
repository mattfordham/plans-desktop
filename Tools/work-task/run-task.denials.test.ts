/**
 * Regression test for the permission-denial predicate (task #116).
 *
 * `isPermissionDenial` must only report a genuine SDK permission denial: a
 * `tool_result` block that is itself an error AND carries the exact SDK wording
 * `Claude requested permissions to use`. A SUCCESSFUL tool result whose content
 * merely mentions the phrase (e.g. a file/log line) must NOT be flagged — that
 * false positive is the bug this test pins down.
 *
 * Run via Node's built-in TypeScript type-stripping (Node >= 22.6):
 *   node --test run-task.denials.test.ts
 * (see package.json `test` script).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { isPermissionDenial } from "./run-task.ts";

test("successful Read result mentioning the phrase is NOT a denial", () => {
  const block = {
    type: "tool_result",
    tool_use_id: "x",
    is_error: false,
    content: "... you haven't granted it yet ...",
  };
  assert.equal(isPermissionDenial(block), false);
});

test("successful result with content-block array is NOT a denial", () => {
  const block = {
    type: "tool_result",
    tool_use_id: "x",
    is_error: false,
    content: [{ type: "text", text: "...haven't granted it yet..." }],
  };
  assert.equal(isPermissionDenial(block), false);
});

test("real denial (is_error + SDK wording) IS a denial", () => {
  const block = {
    type: "tool_result",
    tool_use_id: "y",
    is_error: true,
    content:
      "Claude requested permissions to use Bash, but you haven't granted it yet.",
  };
  assert.equal(isPermissionDenial(block), true);
});

test("error result with unrelated text is NOT a denial", () => {
  const block = {
    type: "tool_result",
    tool_use_id: "z",
    is_error: true,
    content: "Some other tool error",
  };
  assert.equal(isPermissionDenial(block), false);
});

test("a non-tool_result block is NOT a denial", () => {
  const block = { type: "text", text: "Claude requested permissions to use Bash" };
  assert.equal(isPermissionDenial(block), false);
});
