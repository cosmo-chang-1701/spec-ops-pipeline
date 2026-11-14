# Model assignment

`bash SKILL_DIR/scripts/detect_runtime.sh --agent <claude|gemini|codex>` prints one block per
role. Pass **your own runtime** (you know which CLI you are running in; the flag beats env
heuristics — e.g. a Claude Code session may also have `GEMINI_API_KEY` set).

## Roles and defaults

| Role | Runs | Claude (Claude Code) | Gemini (Antigravity) | Codex |
| :--- | :--- | :--- | :--- | :--- |
| Lead (main thread) | Steps 0–6 orchestration, test/DoD runs, subagent disposition, worktrees, PRs | `worker` (`claude-sonnet-5-5` · medium) | `worker` (`gemini-4-hydrogen-high` · high) | `worker` (`gpt-6.1-sol` · medium) |
| `lead` | Planner ([planner.md](planner.md)) & Reviewer ([review-checklist.md](review-checklist.md#reviewer-subagent)) subagents | `claude-opus-5-5` · high | `gemini-4-argon-high` · high | `gpt-6-astra` · high |
| `worker` | Main thread · standard Worker tasks | `claude-sonnet-5-5` · medium | `gemini-4-hydrogen-high` · high | `gpt-6.1-sol` · medium |
| `worker_light` | Light tasks ([tiers](#worker-tier)) | `claude-haiku-5-5` · medium | same as `worker` | `gpt-6-luna` · medium |
| `scout` | Read-only audit sweeps ([scout.md](scout.md)) | `claude-haiku-5-5` · medium | same as `worker` | `gpt-6-luna` · medium |
| Plan Critic | [plan-critic.md](plan-critic.md) | `lead` if any task is H-risk, else `worker` | same rule | same rule |

The Gemini column is the `gemini-4` profile (default). The `model` key of
`~/.gemini/antigravity-cli/settings.json` (display name or id) selects the Antigravity profile;
`detected_by` reports `model:<profile>(settings|default)`:
- `Gemini 4 Hydrogen ...` (`gemini-4-hydrogen`): when `gemini-4-argon-high` is out of quota or
  unavailable, `lead` falls back to `gemini-4-hydrogen-high` · high (or set
  `SOP_LEAD_MODEL=gemini-4-hydrogen-high` if Argon fails during a run), while every other role
  remains `gemini-4-hydrogen-high` · high.
- `Claude ...` (`claude`): `lead` `claude-opus-5-5-high` · high; every other role
  `claude-sonnet-5-5-medium` · medium.
- `Gemini 3.8 Flash ...` (`gemini-3.8-flash`): `lead` `gemini-3.8-flash-high` · high; every
  other role `gemini-3.8-flash-medium` · medium.
- `Gemini 4 ...`, a missing file, or any other model keeps `gemini-4`.

In Codex, if `gpt-6-astra` is out of quota or unavailable, fall back to `gpt-6.1-sol` · high
for `lead` via `SOP_LEAD_MODEL=gpt-6.1-sol`.

Switching to the main-thread (`worker`) model: [SKILL.md](../SKILL.md#model-assignment).
Unknown ecosystems fall back to the Claude column. Each block also has `dispatch_model`, the
value to pass to the runtime's dispatch call (`opus`, `sonnet`, `haiku` in Claude Code).

Overrides: `SOP_LEAD_MODEL`, `SOP_LEAD_EFFORT`,
`SOP_WORKER_MODEL`, `SOP_WORKER_EFFORT`, `SOP_WORKER_LIGHT_MODEL`, `SOP_WORKER_LIGHT_EFFORT`,
`SOP_SCOUT_MODEL`, `SOP_SCOUT_EFFORT`. Setting a model also sets its `dispatch_model`.

## Worker tier
Decide each task's tier at step 2 and show it in the decision matrix's **Worker** column
([execution-plan.md §3](execution-plan.md#3-checkpoint-report)); the user may override it
with the approval. A task is `light` only when **all** of these hold:
- Risk **L**;
- mechanical and behaviour-preserving: rename, move, dead-code removal, lint or type fixes,
  docstrings — no new logic;
- the whitelist covers at most 5 files (`check_scope.sh --list`);
- its DoD can tell done from not done: at least one command is not `PASS`, or the touched
  code is covered by tests the DoD runs.

Everything else is `standard`. Record the tier as `worker_tier` in `state.json`.

**Escalation** — when a `light` task gets REQUEST_CHANGES in round 1 (a failed gate counts),
set `worker_tier` to `standard` and re-dispatch it on the `worker` model. A Worker blocked on a
non-whitelisted file is a spec problem, not a model one: handle it per the review checklist
(ask the user before widening the whitelist) without escalating. The re-dispatch is a new
dispatch (not a message to the old Worker, which keeps its model) with the full spec plus the
`open_findings`, into the same worktree — as on [resume](entrypoints.md#resume-phase-2). Add a
section above the spec's Repo rules telling the new Worker that the worktree already holds the
earlier round's uncommitted changes, to keep them, and to fix only the numbered findings.
Rounds keep counting; escalation does not reset them.
