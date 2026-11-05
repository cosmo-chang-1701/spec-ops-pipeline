---
name: spec-ops-pipeline
description: >-
  Runs a Lead-Worker workflow for code audits and delegated refactoring. The Lead
  (reviewer/orchestrator) scans code read-only, writes a gap analysis, drafts a
  whitelisted spec with a Definition of Done, dispatches a Worker subagent to
  implement it inside an isolated git worktree, gates the result (scope + DoD), and
  reviews the PR diff. With several tasks it runs Workers in parallel — all at once
  when the tasks are independent, or in dependency-ordered stages (parallel within a
  stage, integrated between stages) when they are related. Use when the user asks to
  audit a codebase and fix what is found, to delegate a refactor or cleanup to one or
  more subagents in separate worktrees, to run a spec-driven or Lead-Worker
  implementation, or to review a worker's branch before merging.
---

# Spec Ops Pipeline (Lead-Worker)

`SKILL_DIR` = the directory containing this file.

## Role boundaries (non-negotiable)

| Role | May | Must not |
| :--- | :--- | :--- |
| **Lead** (you) | Read/search code, run tests/linters/builds, write specs, reviews and run state (in the run dir), manage worktrees via `worktree.sh`; after the user's explicit yes, run `migrate_to_bare.sh --apply`; once the checkpoint is approved, commit approved work on `sop/*` branches (staged: also between stages) and run `pr.sh open` / `pr.sh merge` (merge per `auto_merge_risk`); per `auto_cleanup` (or with the user's consent) [clean up](references/execution-plan.md#6a-cleanup) after merged PRs | Edit, create, delete, or move any application file — in the main checkout **or** a worker worktree (sole exceptions: `migrate_to_bare.sh --apply` and the fast-forward of `worktree.sh sync`); resolve merge conflicts by hand; merge a task that was not APPROVEd, use `--admin`, or get around branch protection |
| **Worker** (subagent) | Edit whitelisted files in its worktree until the DoD passes | Touch non-whitelisted files, commit/push, work outside its worktree |

Tempted to "just fix it"? Write a spec.

## Model assignment
Preflight `runtime` gives the models per role (`lead` = phase 1, `lead_phase2`,
`worker`, `worker_light`, `scout`); the Reviewer runs on `lead`. Roles, defaults,
overrides, tiers: [models.md](references/models.md). If you are not on the Lead model of
the current phase, tell the user how to switch (`/model`, `/effort` in Claude Code); do not
silently continue — except a `single` run, which keeps the phase 1 Lead model.

## Sessions and context
- **Phase 1**: steps 0–2 on the phase 1 Lead model.
- **Phase 2**: steps 3–6. `split`: starts with [Resume](#resume-phase-2) in a **fresh
  session** on the phase 2 Lead model, reading only plan, state and the current stage's
  specs (self-contained). `single`: continues in the same session.

`session_split` (env `SOP_SESSION_SPLIT`): `auto` (default) = `split` for any H-risk task,
three or more tasks, or `staged` mode, else `single`; `always` → `split`; `never` → `single`.

The checkpoint shows it; the user may override.

Run state lives in the **run dir** (`run.run_dir`, `<git common dir>/sop-run/`): outside every
work tree, shared by all worktrees, kept across sessions. Never use a session scratchpad.

**Command output** — run every lint/test/build/DoD command through
`bash SKILL_DIR/scripts/run_logged.sh <run dir>/logs/<slug>-<step>-<n>.log '<command>'`
(prints `exit=<rc> lines=<n> log=<path>` + the last 40 lines on failure). Read more of the
log only when the tail does not explain a failure. Never put full test output in the chat.

## Workflow

### 0. Preflight
`bash SKILL_DIR/scripts/preflight.sh --agent <claude|gemini|codex> --fetch` (your own runtime;
`--fetch` updates a remote `default_base` first) prints one JSON line: `runtime` (note `worker`, `session_split`),
`config` (note `source_worktree`, `default_base`, `provision`, `max_parallel`,
`auto_merge_risk`, `merge_method`, `auto_cleanup`; [layout](references/scripts-and-layout.md)),
`leftovers`, `run`, `pr`, `baseline`, `base_check`, `docker_pool`. In a bare layout run Lead git/test
commands inside `source_worktree`. Act on:
1. `run.has_state: true` (run in progress): ask the user whether to [resume](#resume-phase-2)
   it, [clean it up](#cleanup-after-the-user-merges) (if all its tasks have PRs waiting for
   the user), or archive it (`worktree.sh rundir --archive`) and start over.
2. `leftovers` (earlier runs' tasks): mention them.
3. `config.offer_bare_migration: true`: run `bash SKILL_DIR/scripts/migrate_to_bare.sh` (dry
   run), ask the user whether to convert to the **bare-repo worktree layout**, formatted per
   [bare-layout.md](references/bare-layout.md). Only on an explicit yes:
   `migrate_to_bare.sh --apply`, re-run `preflight.sh`, re-read the agent docs from the new
   `source_worktree`. Blocked or declined → standard layout.
4. `pr.ok: false`: the run only commits locally; the checkpoint says so. Note `pr.into`.
   Merge rules: [execution-plan.md](references/execution-plan.md#auto-merge-modes).
5. `base_check.match: false`, `fetch_error` or `error`: agree
   on the base with the user first.
6. `docker_pool.error`: tell the user capacity is unknown; else `docker: false`: skip; else
   `free` < `config.max_parallel`: warn (step 3 re-checks).
7. `baseline` = output of `git status --porcelain=v1 && git diff HEAD | sha256sum`, already
   run in `source_worktree`. Keep it for `state.json`.

### 1. Audit (read-only)
- Establish scope with the user (paths; security / perf / debt / spec gaps).
- Scan statically; for a large scope first sweep with parallel read-only scouts
  ([scout.md](references/scout.md)) and verify their leads. Run the project's existing
  lint/test/type-check commands for ground truth via `run_logged.sh` (logs `audit-<n>.log`);
  do not install tools or change config.
- Produce a **gap report**: numbered findings with `file:line`, severity, evidence, proposed
  fix. Group them into Worker-sized tasks with small non-overlapping whitelists.
- With several tasks, draft the **execution plan** per
  [execution-plan.md](references/execution-plan.md): no dependencies → `independent` (all
  parallel); related → `staged` (dependency-ordered stages, parallel within a
  stage, each built on the previous stage's integrated result).

### 2. Spec (checkpoint)
- For each task fill [worker-spec-template.md](references/worker-spec-template.md) and pick its
  Worker tier ([models.md](references/models.md#worker-tier)). Fill **Repo rules** from the
  agent docs (`AGENTS.md`, `CLAUDE.md`, also in directories the whitelist touches): test/lint
  commands, flags, language rules; add repo pitfalls from your memory and any `worker_notes`.
  Workers cannot see your context. Write DoD commands as those rules require.
- Save to the run dir, never a worktree: `gap-report.md`, `plan.md`, `spec-<slug>.md`, `<slug>.wl`.
- **Overlap check** per stage: `bash SKILL_DIR/scripts/check_scope.sh --overlap
  <source_worktree> <slug>.wl...`; `OVERLAP` → re-split or re-stage; check each `POSSIBLE` by hand.
- **DoD dry run**: run each DoD command of `independent` / stage-1 tasks in `source_worktree`
  through `run_logged.sh` (logs `<slug>-dry-<n>.log`), note its class in the spec, fix `BROKEN`
  ones ([details](references/worker-spec-template.md#dod-dry-run)); stage 2+ at step 3.
- **Plan Critic**: with 2+ tasks, `staged` mode, an H-risk task, or on request: a read-only
  critic (`lead` model only if a task is H-risk, else `lead_phase2`); decide on each
  finding per [plan-critic.md](references/plan-critic.md). One round.
- **Show the checkpoint report and wait for approval** before step 3, in the format of
  [execution-plan.md §3](references/execution-plan.md#3-checkpoint-report). The approval must explicitly cover:
  in `staged` mode the inter-stage local commits and merges; always the automatic commit,
  push, PR and — per the Merge column — merge after APPROVE; with `auto_cleanup` the cleanup
  after each merge; and, when the Docker pool line says `prune: ask`, `worktree.sh pool --prune`. Wording in §3.
- **Phase boundary**: after approval write `<run dir>/state.json`
  ([§7](references/execution-plan.md#7-run-state)) with `phase: 2` and the agreed `session`, then:
  - `split`, tell the user:
    > Plan approved and saved to `<run dir>`. Run `/clear`, switch to the phase 2 Lead
    > (`/model <lead_phase2.model>`, `/effort <lead_phase2.effort>`), then invoke this skill
    > with `resume`.

    (Codex / Antigravity: start a new session on `lead_phase2`.)
  - `single`: tell the user the plan is saved to `<run dir>` and the run continues here; go to step 3 without switching models (`resume` still works).

### Resume (phase 2)
On `resume`: [entrypoints.md](references/entrypoints.md#resume-phase-2).

### Cleanup (after the user merges)
On `cleanup`: [entrypoints.md](references/entrypoints.md#cleanup-after-the-user-merges).

Steps 3–5 run **once per stage** (`independent` = a single stage), in plan order. Keep
`state.json` current: update a task's status on dispatch, each review round, approval or
deferral, and the stage when integrated.

### 3. Worktree + dispatch
1. Before creating the stage's worktrees: `bash SKILL_DIR/scripts/worktree.sh pool`.
   `docker: false` → skip; `error` → tell the user, ask first. Else if `free` < the stage's
   task count, run `worktree.sh pool --prune` only if the approval covers it (it removes all
   projects' unused Compose networks; they are recreated), else ask the user.
2. For each task: `bash SKILL_DIR/scripts/worktree.sh create <slug> [--base <ref>]` (stage 1:
   omit `--base`; stage 2+: `--base sop-stage/<n-1>`; `worktree.sh path <slug>` previews).
   Check `provisioned` in the output; stop if an expected entry is missing. Stage 2+: dry-run each task's DoD in its new worktree
   through `run_logged.sh` before dispatch (path/flag fixes only; else ask).
3. Insert the worktree path and base into each spec, then dispatch **all of the stage's
   Workers in parallel** per [dispatch.md](references/dispatch.md), each on the model of its
   `worker_tier` (`worker` / `worker_light`; cap `max_parallel`).

### 4. Gate (per task)
1. `bash SKILL_DIR/scripts/check_scope.sh <worktree> <whitelist-file>` must exit 0; on
   violations the Worker reverts them (counts as a review round).
2. Re-run every DoD command yourself in the worktree through `run_logged.sh` (logs
   `<slug>-gate-r<round>-<n>.log`); all must exit 0.

### 5. Review (per task) + stage barrier
Follow [review-checklist.md](references/review-checklist.md): the diff is reviewed on
the `lead` model (`split`: read-only Reviewer subagent, you verify its findings; `single`: you) against the recorded base. Issue APPROVE or REQUEST_CHANGES with numbered `file:line`
findings; loop with the Worker at most **3 rounds**, then escalate to the user.
Tasks loop independently. A `light` task failing round 1 is re-dispatched on the
`worker` model ([models.md](references/models.md#worker-tier)).
- `independent`: on APPROVE, commit, push, open the PR with `pr.sh` and merge it when the
  [auto-merge rules](references/execution-plan.md#auto-merge-modes) allow, with no question
  ([§4a](references/execution-plan.md#4a-after-approve-independent-mode)).
- `staged`: when every task in the stage is APPROVED, commit each locally, run
  `worktree.sh integrate <n> --base <stage base> sop/<slug>...`, and pass the integration
  gate (all of the stage's DoD in the stage worktree) before the next stage; conflicts,
  integration failures and escalations: [execution-plan.md](references/execution-plan.md#4-running-a-stage).
  With more stages to go, set `current_stage` to the next one in `state.json` and go on in the same session.
  Offer a fresh session (`/clear`, then `resume`) only when the context has grown large (two
  stages ran, or many review rounds); it is safe here.

### 6. Close-out
1. Re-run the step 0 baseline command; it must match, else report exactly what changed in the
   main checkout — do not "fix" it yourself.
2. PRs: `independent` PRs already exist (§5); list each as `merged`, `open` (reason) or local
   only. `staged`: open the single PR from the last `sop-stage/<n>` with `pr.sh` (merge per
   `auto_merge_risk`, [§6](references/execution-plan.md#6-close-out)).
3. [Cleanup](references/execution-plan.md#6a-cleanup) of merged PRs' worktrees and branches,
   `worktree.sh sync`, and — once every task is cleaned — `worktree.sh rundir --archive`.
   No question only with `auto_cleanup` in the approval, else ask first. Never `--force`.
4. Final summary: findings addressed, deferred (and blocked dependents), branches/PRs
   with state, what was cleaned up and what is left. If PRs await the user, end with: after
   merging them, invoke this skill with `cleanup`.

## Scripts and layout
Usage, exit codes, worktree paths, provisioning, config overrides:
[scripts-and-layout.md](references/scripts-and-layout.md).
