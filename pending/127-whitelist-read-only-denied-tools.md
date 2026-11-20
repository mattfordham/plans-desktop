# Whitelist read-only denied tool calls from the "incomplete information" warning

**ID:** 127
**Created:** 2026-11-20T14:11
**Type:** bug
**Status:** pending

## What
This should be whitelisted.

(Captured from a pasted screenshot of the Plans app's own plan-detail view. The
screenshot shows the orange caution banner:

> ⚠️ **1 tool call denied — the plan may be built on incomplete information**
> `mcp__plugin_figma_figma__get_variable_defs`

with the plan body below it reading "What: Update color NAMES to match Figma
frame below.")

The denied tool is `mcp__plugin_figma_figma__get_variable_defs` — a **read-only**
Figma MCP tool. Being denied a read-only inspection tool does not mean "the plan
may be built on incomplete information" in the alarming sense the banner implies,
and surfacing it as a caution is noise. Certain tools like this should be
whitelisted so that a denial of them is not counted toward, or surfaced by, the
denied-tools warning in the plan-detail view.

## Why
_To be filled during elaboration_

## How Summary
_To be filled during elaboration_

## How
_To be filled during elaboration_

## Verification
_To be filled during elaboration_

## Impact Scope
_To be filled during elaboration (if 3+ files affected)_

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
_To be filled during execution_

## Changes
_To be filled during execution_

## Notes
_Additional context_
