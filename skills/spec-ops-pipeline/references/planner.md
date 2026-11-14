# Planner (audit & spec subagent)

A read-only subagent on the **`lead` model** performs the deep audit analysis, groups
findings into tasks with non-overlapping whitelists, drafts the execution plan
(`independent` or `staged`), and writes the initial Worker specs. The main thread (Lead /
Orchestrator, running on the `worker` model) verifies the cited evidence, saves the
artefacts to the run dir, runs `check_scope.sh --overlap` and the DoD dry run, and owns the
checkpoint report.

## Inputs (written to `<run dir>/planner-input.md`)
- `source_worktree` absolute path, `default_base`, and its SHA;
- agreed audit scope (paths and concerns: security / perf / debt / spec gaps);
- summary lines and log paths of the existing lint / test / type-check commands run at step 1
  via `run_logged.sh` (`<run dir>/logs/audit-<n>.log`);
- paths of any Scout lead files (`<run dir>/scout-<area>.md`, see [scout.md](scout.md));
- repo rules from `AGENTS.md` / `CLAUDE.md` (at the root and in directories the scope
  touches), known repo pitfalls, `worker_notes`, and `max_parallel`;
- paths to [worker-spec-template.md](worker-spec-template.md),
  [execution-plan.md](execution-plan.md) (§1–2), and [models.md](models.md#worker-tier).

## Prompt
```markdown
# Planner

You audit the agreed scope and draft the refactoring plan and Worker specs. You are
read-only: do not edit, create, or delete files, and do not run tests, builds, installs,
or git commands that change state. Reading files and searching (`git grep`, `rg`,
`git log`, `git show`) are allowed.

Inputs: <run dir>/planner-input.md (source_worktree, base, scope, audit test results,
scout leads if any, repo rules, template paths).

1. Audit — inspect the code in `source_worktree`. If scout leads are listed, open and
   verify each cited `file:line` (with a small range, not the whole file) and drop what you
   cannot confirm; areas a scout marked clean need no re-read unless another finding points
   there. Every finding needs `file:line` evidence from the code or audit test logs — no
   evidence, no finding.
2. Group & plan — group findings into Worker-sized tasks with small, non-overlapping
   whitelists. Analyse dependencies per execution-plan.md §1–2 (`independent` or `staged`),
   assign each task's Risk (`H`/`M`/`L`) and Worker tier (`light`/`standard` per models.md),
   and note shared static or runtime resources.
3. Specs — for each task, draft a complete spec following worker-spec-template.md (fill Repo
   rules, Goal, Context, Whitelist, Forbidden, Steps, and runnable Definition of Done
   commands without `# baseline:` notes yet — the Lead dry-runs them next) and its
   `<slug>.wl` whitelist.

Output only these sections (`gap-report.md`, `plan.md`, and for each task `spec-<slug>.md`
and `<slug>.wl`), clearly delimited by file name.
```

## Dispatch
Always use the `lead` block of `detect_runtime.sh` (`lead.model`, `lead.effort`,
`lead.dispatch_model`):

| Runtime | Call |
| :--- | :--- |
| Claude Code | `Agent` with `subagent_type: Plan` (no edit tools), `model: <lead.dispatch_model>`, `effort: <lead.effort>`, the prompt above. No `isolation`. |
| Codex | `codex exec -C "<source_worktree>" -m "<lead.model>" -c model_reasoning_effort="<lead.effort>" -s read-only -o "<run dir>/planner-output.md" - < "<run dir>/planner-prompt.md"` |
| Antigravity | `(cd "<source_worktree>" && agy -p "$(cat "<run dir>/planner-prompt.md")" --model "<lead.dispatch_model>" --mode plan --output-format text) > "<run dir>/planner-output.md"` |

Afterwards re-run the step 0 baseline command on `source_worktree`; it must still match.

## Lead disposition
1. Open the cited `file:line` of each finding yourself (small line range); drop any finding
   whose evidence does not hold in `source_worktree`.
2. Save `<run dir>/gap-report.md`, `<run dir>/plan.md`, and each `<run dir>/spec-<slug>.md`
   and `<run dir>/<slug>.wl` (never inside a worktree).
3. Continue at step 2 with `check_scope.sh --overlap`, the DoD dry run, and the Plan Critic
   ([plan-critic.md](plan-critic.md)).
4. When the user asks for adjustments at the checkpoint: apply localized changes (whitelist,
   risk level, merge mode, simple task split/merge) directly to the files in `<run dir>/`;
   re-dispatch the Planner on `lead` only when the user requests a major architectural
   redesign.
