# Entry points

The skill is also invoked with `resume` (phase 2 in a fresh session) or `cleanup` (after the user merged the PRs).

## Resume (phase 2)
Entered when the skill is invoked with `resume`, or when preflight finds a run in progress
and the user chooses to resume. Do not redo steps 0–2.
1. `preflight.sh --agent <claude|gemini|codex> --fetch` as in [step 0](../SKILL.md#0-preflight);
   use only `runtime`, `run`, `baseline`, `base_check` and `leftovers`, compare them with
   `state.json`, and do not re-ask the "resume?" question or overwrite the state. Check you are
   on the `lead_phase2` model. `run.run_dir` → `run_dir`.
2. Read `state.json` and `plan.md`, then only the specs and whitelists of `current_stage`
   (not the gap report; read it only if a finding's wording is needed to decide something).
3. The preflight `baseline` (the step 0 baseline command on `source_worktree`) must equal
   `baseline` in the state. Check `git rev-parse <default_base>` still equals
   `default_base_sha` (the `--fetch` preflight already refreshed a remote base). On any mismatch stop and ask the user — the plan was approved for that code.
4. `leftovers` (`worktree.sh status`): compare with the task states in `state.json`. Worktrees of the
   current stage that already exist are reused, not re-created; a task recorded as
   `dispatched` or `in-review` has no reachable Worker anymore — re-dispatch it on its
   `worker_tier` with its spec (plus the open findings, if any) into its existing worktree,
   telling the new Worker to keep the uncommitted changes already there
   ([models.md](models.md#worker-tier)). A task recorded as `approved` continues
   with its commit; `committed` (with `pr_enabled`) re-runs `pr.sh open` (it reuses an open PR);
   `pr-open` with `merge: auto`, no `pr_state` and the merge conditions met re-runs `pr.sh merge`
   ([execution-plan.md §4a](execution-plan.md#4a-after-approve-independent-mode)).
5. Continue at step 3 for `current_stage`.

## Cleanup (after the user merges)
Entered when the skill is invoked with `cleanup`, or when preflight finds a run whose tasks
all have PRs waiting for the user and the user chooses to clean it up. The invocation is the
user's consent, whatever `auto_cleanup` says; no model switch is needed.
1. `preflight.sh --agent <claude|gemini|codex> --fetch`; use only `runtime`, `config`, `run` and `leftovers`, and do not re-ask the "clean up?" question or overwrite the state. Read `state.json`.
2. For each task with status `pr-open` (staged: the run's `final_pr`), run
   `pr.sh state <pr>`: `MERGED` → status `merged`; `OPEN` / `CLOSED` → report it and leave it.
3. Run the [cleanup](execution-plan.md#6a-cleanup) and report what was cleaned and
   what is left.
