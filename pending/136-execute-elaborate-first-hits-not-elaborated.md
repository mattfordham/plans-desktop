# Execute with "elaborate first" enabled still hits the not-elaborated gate

**ID:** 136
**Created:** 2026-11-25T11:52
**Type:** bug
**Status:** pending

## What
I'm pretty sure I executed this with the "elaborate first" checkbox enabled. It seems to not have worked.

Evidence (screenshot): a `pending`, un-elaborated task was Executed from the browser. Instead of the run auto-elaborating first and then executing, the agent dock shows the run reaching the standard "Not elaborated" gate and parking on an `AskUserQuestion` ("Task #NNN hasn't been elaborated yet. … Elaborate now (recommended) / Execute anyway / Resolve for me"). So the pre-run "elaborate first" option did not take effect — the execute run behaved as if the checkbox were off.

![pasted image](file:///Users/matt/Library/Application%20Support/Plans/attachments/A429E818-6149-4D1A-AAA8-77B3392EBB66.png)

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
