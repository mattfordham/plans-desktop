/**
 * Guards the `BASE_ALLOWED_TOOLS` allowlist: the benign Playwright/Figma MCP
 * tools plans-cc #057 added to the skills must be present, and the dangerous
 * ones must stay excluded (desktop runs use `permissionMode: "acceptEdits"`,
 * where any MCP tool absent from this allowlist is hard-denied).
 *
 * Run via Node's built-in TypeScript type-stripping (Node >= 22.6):
 *   node --test run-task.allowlist.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE_ALLOWED_TOOLS } from "./run-task.ts";

const PRESENT = [
  "mcp__playwright__browser_close",
  "mcp__playwright__browser_click",
  "mcp__playwright__browser_type",
  "mcp__playwright__browser_console_messages",
  "mcp__figma-dev-mode-mcp-server__get_variable_defs",
  "mcp__plugin_figma_figma__create_session",
];

const ABSENT = [
  "mcp__playwright__browser_fill_form",
  "mcp__playwright__browser_run_code_unsafe",
];

test("benign Playwright/Figma MCP tools are on the base allowlist", () => {
  for (const tool of PRESENT) {
    assert.ok(
      BASE_ALLOWED_TOOLS.includes(tool),
      `expected ${tool} to be on BASE_ALLOWED_TOOLS`,
    );
  }
});

test("dangerous Playwright MCP tools stay excluded from the base allowlist", () => {
  for (const tool of ABSENT) {
    assert.ok(
      !BASE_ALLOWED_TOOLS.includes(tool),
      `expected ${tool} to be excluded from BASE_ALLOWED_TOOLS`,
    );
  }
});
