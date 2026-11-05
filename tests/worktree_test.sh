#!/usr/bin/env bash
# Tests for worktree.sh (config, status, provision) and wt.sh.  Run: bash tests/worktree_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W=$SCRIPTS/worktree.sh
WT=$SCRIPTS/wt.sh

section "config: offer_bare_migration"
std=$(make_repo std)
check_eq "standard repo: offered" "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" True
mkdir -p "$std/.agents" && echo '{"offerBareLayout": false}' >"$std/.agents/spec-ops-pipeline.json"
check_eq "offerBareLayout false: not offered" \
  "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" False

repo=$(make_repo bare)
(cd "$repo" && echo SECRET=1 >.env && bash "$SCRIPTS/migrate_to_bare.sh" --apply >/dev/null 2>&1)
check_eq "bare layout: not offered" "$(cd "$repo" && bash "$W" config | json_get '["offer_bare_migration"]')" False

section "config: repo config found from the container root"
mkdir -p "$repo/main/.agents" && echo '{"maxParallel": 2}' >"$repo/main/.agents/spec-ops-pipeline.json"
check_eq "maxParallel read from main/.agents/spec-ops-pipeline.json" \
  "$(cd "$repo" && bash "$W" config | json_get '["max_parallel"]')" 2
rm -r "$repo/main/.agents"

section "config: autoMergeRisk / mergeMethod"
cfg_get() { (cd "$std" && bash "$W" config | json_get "$1"); }
risk_get() { (cd "$std" && env "$@" bash "$W" config | json_get '["auto_merge_risk"]'); }
cfgfile=$std/.agents/spec-ops-pipeline.json
check_eq "autoMergeRisk defaults to L, M" "$(cfg_get '["auto_merge_risk"]')" "['L', 'M']"
check_eq "mergeMethod defaults to squash" "$(cfg_get '["merge_method"]')" squash
echo '{"autoMergeRisk": ["H", "L"], "mergeMethod": "rebase"}' >"$cfgfile"
check_eq "autoMergeRisk read from the config (ordered)" "$(cfg_get '["auto_merge_risk"]')" "['L', 'H']"
check_eq "mergeMethod read from the config" "$(cfg_get '["merge_method"]')" rebase
check_eq "SOP_AUTO_MERGE_RISK wins over the config" "$(risk_get SOP_AUTO_MERGE_RISK=M)" "['M']"
check_eq "SOP_AUTO_MERGE_RISK=none" "$(risk_get SOP_AUTO_MERGE_RISK=none)" "[]"
check_eq "SOP_MERGE_METHOD wins over the config" \
  "$(cd "$std" && SOP_MERGE_METHOD=merge bash "$W" config | json_get '["merge_method"]')" merge
(cd "$std" && SOP_AUTO_MERGE_RISK=X bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid SOP_AUTO_MERGE_RISK: exit 2" "$rc" 2
echo '{"autoMergeRisk": "L"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "autoMergeRisk not a list: exit 2" "$rc" 2
echo '{"mergeMethod": "ff"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid mergeMethod in the config: exit 2" "$rc" 2

section "config: removed autoMerge"
echo '{"autoMerge": "manual"}' >"$cfgfile"
err=$(cd "$std" && bash "$W" config 2>&1 >/dev/null); rc=$?
check_eq "deciding autoMerge in the repo config: exit 2" "$rc" 2
check "removed autoMerge: names the file and the replacement" \
  bash -c 'grep -qF "$1" <<<"$2" && grep -qF autoMergeRisk <<<"$2"' _ "$cfgfile" "$err"
echo '{"autoMerge": "manual", "autoMergeRisk": ["L"]}' >"$cfgfile"
err=$(cd "$std" && bash "$W" config 2>&1 >/dev/null); rc=$?
check_eq "autoMerge next to autoMergeRisk: exit 0" "$rc" 0
check "autoMerge next to autoMergeRisk: warned" grep -q "removed and is ignored" <<<"$err"
check_eq "autoMerge next to autoMergeRisk: autoMergeRisk applies" "$(cfg_get '["auto_merge_risk"]')" "['L']"
echo '{}' >"$cfgfile"
(cd "$std" && SOP_AUTO_MERGE=manual bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "deciding SOP_AUTO_MERGE: exit 2" "$rc" 2
check_eq "SOP_AUTO_MERGE_RISK outranks SOP_AUTO_MERGE" \
  "$(cd "$std" && SOP_AUTO_MERGE=manual SOP_AUTO_MERGE_RISK=none bash "$W" config 2>/dev/null | json_get '["auto_merge_risk"]')" "[]"
echo '{"autoMerge": "all"}' >"$cfgfile"
check_eq "SOP_AUTO_MERGE_RISK outranks a file's autoMerge" \
  "$(cd "$std" && SOP_AUTO_MERGE_RISK=L bash "$W" config 2>/dev/null | json_get '["auto_merge_risk"]')" "['L']"
echo '{"autoMergeRisk": 3' >"$cfgfile"
err=$(cd "$std" && bash "$W" config 2>&1 >/dev/null); rc=$?
check_eq "unparsable config: exit 2" "$rc" 2
check "unparsable config: one-line error, no traceback" bash -c '! grep -q Traceback <<<"$1"' _ "$err"
echo '{}' >"$cfgfile"

section "config: autoCleanup"
check_eq "autoCleanup defaults to true" "$(cfg_get '["auto_cleanup"]')" True
echo '{"autoCleanup": false}' >"$cfgfile"
check_eq "autoCleanup read from the config" "$(cfg_get '["auto_cleanup"]')" False
check_eq "SOP_AUTO_CLEANUP=1 wins over the config" \
  "$(cd "$std" && SOP_AUTO_CLEANUP=1 bash "$W" config | json_get '["auto_cleanup"]')" True
(cd "$std" && SOP_AUTO_CLEANUP=yes bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid SOP_AUTO_CLEANUP: exit 2" "$rc" 2
echo '{"autoCleanup": "no"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "autoCleanup not a bool: exit 2" "$rc" 2

section "config: user config"
userfile=$XDG_CONFIG_HOME/spec-ops-pipeline/config.json
mkdir -p "$(dirname "$userfile")"
echo '{"autoMergeRisk": ["L"], "mergeMethod": "merge", "maxParallel": 6, "autoCleanup": false,
  "defaultBase": "nope"}' >"$userfile"
echo '{"offerBareLayout": false}' >"$cfgfile"
check_eq "user config found" "$(cfg_get '["user_config_file"]')" "$userfile"
check_eq "autoMergeRisk from the user config" "$(cfg_get '["auto_merge_risk"]')" "['L']"
check_eq "maxParallel from the user config" "$(cfg_get '["max_parallel"]')" 6
check_eq "autoCleanup from the user config" "$(cfg_get '["auto_cleanup"]')" False
check_eq "repo-only keys ignored in the user config" "$(cfg_get '["default_base"]')" HEAD
echo '{"offerBareLayout": false, "autoMergeRisk": ["L", "M", "H"]}' >"$cfgfile"
check_eq "repo config wins over the user config" "$(cfg_get '["auto_merge_risk"]')" "['L', 'M', 'H']"
check_eq "other user keys still apply" "$(cfg_get '["merge_method"]')" merge
echo '{"offerBareLayout": false, "autoMerge": "manual"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "repo autoMerge outranks the user's autoMergeRisk: exit 2" "$rc" 2
echo '{"offerBareLayout": false}' >"$cfgfile"
echo '{"autoMergeRisk": ["L"], "autoMerge": "all"}' >"$userfile"
check_eq "user autoMerge beside autoMergeRisk: ignored" "$(cfg_get '["auto_merge_risk"]')" "['L']"
echo '{"mergeMethod": "ff"}' >"$userfile"
err=$(cd "$std" && bash "$W" config 2>&1 >/dev/null)
check "invalid value names the user config" grep -qF "$userfile" <<<"$err"
check_eq "SOP_USER_CONFIG overrides the path" \
  "$(cd "$std" && SOP_USER_CONFIG=$cfgfile bash "$W" config | json_get '["user_config_file"]')" "$cfgfile"
(cd "$std" && SOP_USER_CONFIG=$WORK/missing.json bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "unreadable SOP_USER_CONFIG: exit 2" "$rc" 2
rm -r "$XDG_CONFIG_HOME"
echo '{"offerBareLayout": false}' >"$cfgfile"

section "status"
(cd "$repo" && bash "$W" create clean-task >/dev/null 2>&1 && bash "$W" create dirty-task >/dev/null 2>&1)
check "create provisioned .env" test -f "$repo/sop/clean-task/.env"
echo change >>"$repo/sop/dirty-task/a.txt"
echo new >"$repo/sop/dirty-task/new.txt"
out=$(cd "$repo" && bash "$W" status)
line() { grep "\"slug\":\"$1\"" <<<"$out"; }
check_eq "clean task is clean" "$(line clean-task | json_get '["state"]')" clean
check_eq "dirty task is dirty" "$(line dirty-task | json_get '["state"]')" dirty
check_eq "dirty task: 1 unstaged" "$(line dirty-task | json_get '["unstaged"]')" 1
check_eq "dirty task: 1 untracked" "$(line dirty-task | json_get '["untracked"]')" 1
check_eq "base recorded" "$(line clean-task | json_get '["base"]')" "$(git -C "$repo/main" rev-parse origin/main)"
check_eq "ahead_of_base 0" "$(line clean-task | json_get '["ahead_of_base"]')" 0
check "main worktree not listed" bash -c "! grep -q '\"branch\":\"main\"' <<<'$out'"
(cd "$repo" && bash "$W" status --check >/dev/null); rc=$?
check_eq "--check with a dirty task: exit 1" "$rc" 1
rm -rf "$repo/sop/clean-task"
check_eq "deleted worktree dir is missing" \
  "$(cd "$repo" && bash "$W" status | grep '"clean-task"' | json_get '["state"]')" missing
git -C "$repo/main" worktree prune

section "provision"
rm -f "$repo/sop/dirty-task/.env"
out=$(cd "$repo" && bash "$W" provision sop/dirty-task 2>/dev/null)
check ".env provisioned into an existing worktree" test -f "$repo/sop/dirty-task/.env"
check "provision reports it" grep -q 'copy:.env' <<<"$out"
(cd "$repo" && bash "$W" provision main >/dev/null 2>&1); rc=$?
check_eq "source worktree refused" "$rc" 2
(cd "$repo" && bash "$W" provision "$WORK" >/dev/null 2>&1); rc=$?
check_eq "foreign directory refused" "$rc" 2

section "wt.sh"
git -C "$repo/main" branch local-branch
git -C "$WORK/bare.up" branch remote-branch && git -C "$repo/main" fetch -q origin
(cd "$repo" && bash "$WT" add feat/new >/dev/null 2>&1); rc=$?
check_eq "add new branch" "$rc" 0
check_eq "new branch starts at origin/main" "$(git -C "$repo/feat/new" rev-parse HEAD)" "$(git -C "$repo/main" rev-parse origin/main)"
check "new branch has no upstream" bash -c "! git -C '$repo/feat/new' rev-parse @{u}"
check "new worktree provisioned" test -f "$repo/feat/new/.env"
(cd "$repo" && bash "$WT" add local-branch >/dev/null 2>&1)
check_eq "existing local branch checked out" "$(git -C "$repo/local-branch" branch --show-current)" local-branch
(cd "$repo" && bash "$WT" add remote-branch >/dev/null 2>&1)
check_eq "remote-only branch tracks origin" "$(git -C "$repo/remote-branch" rev-parse --abbrev-ref @{u})" origin/remote-branch
(cd "$repo" && bash "$WT" add sop/x >/dev/null 2>&1); rc=$?
check_eq "sop/ branch refused" "$rc" 2
(cd "$repo/feat/new" && bash "$WT" st --check >/dev/null); rc=$?
check_eq "status --check with a dirty spec-ops-pipeline task: exit 1" "$rc" 1
check "status -s lists feat/new" bash -c "cd '$repo' && bash '$WT' st -s | grep -q '^CLEAN   feat/new'"
echo x >"$repo/feat/new/x.txt"
(cd "$repo" && bash "$WT" remove feat/new >/dev/null 2>&1); rc=$?
check_eq "remove dirty worktree refused" "$rc" 2
(cd "$repo" && bash "$WT" remove feat/new --force >/dev/null 2>&1)
check "remove --force drops worktree and empty feat/" test ! -e "$repo/feat"
check "branch kept after remove" git -C "$repo/main" show-ref --verify refs/heads/feat/new
(cd "$repo" && bash "$WT" remove main >/dev/null 2>&1); rc=$?
check_eq "default-branch worktree refused" "$rc" 2
(cd "$std" && bash "$WT" list >/dev/null 2>&1); rc=$?
check_eq "standard layout refused" "$rc" 2

section "wt.sh link-config"
mkdir -p "$repo/main/.claude/skills" && echo agents >"$repo/main/AGENTS.md" && echo mine >"$repo/main/CLAUDE.md"
echo root >"$repo/CLAUDE.md"
(cd "$repo/main" && bash "$WT" link-config >/dev/null 2>&1); rc=$?
check_eq "link-config exits 0" "$rc" 0
check_eq ".claude linked relative to the root" "$(readlink "$repo/.claude")" main/.claude
check_eq "AGENTS.md linked" "$(readlink "$repo/AGENTS.md")" main/AGENTS.md
check_eq "real CLAUDE.md at the root left as is" "$(cat "$repo/CLAUDE.md")" root
check "nothing linked for config main/ lacks" test ! -e "$repo/.gemini" -a ! -L "$repo/.gemini"
check "second run reports up to date" bash -c "cd '$repo' && bash '$WT' link-config | grep -q 'up to date'"
rm "$repo/.claude" && ln -s old/.claude "$repo/.claude"
(cd "$repo" && bash "$WT" link-config >/dev/null 2>&1)
check_eq "dangling link re-pointed" "$(readlink "$repo/.claude")" main/.claude
rm "$repo/main/AGENTS.md"
(cd "$repo" && bash "$WT" link-config >/dev/null 2>&1)
check "link removed once main/ has no AGENTS.md" test ! -L "$repo/AGENTS.md"
rm -r "$repo/.claude" "$repo/CLAUDE.md" "$repo/main/.claude" "$repo/main/CLAUDE.md"

section "rundir"
out=$(cd "$repo/sop/dirty-task" && bash "$W" rundir)
rd=$(json_get '["run_dir"]' <<<"$out")
check_eq "run dir in the git common dir" "$rd" "$(git -C "$repo/main" rev-parse --path-format=absolute --git-common-dir)/sop-run"
check_eq "same run dir from the source worktree" "$(cd "$repo/main" && bash "$W" rundir | json_get '["run_dir"]')" "$rd"
check "logs dir created" test -d "$rd/logs"
check_eq "no state yet" "$(json_get '["has_state"]' <<<"$out")" False
echo '{}' >"$rd/state.json"
check_eq "state detected" "$(cd "$repo" && bash "$W" rundir | json_get '["has_state"]')" True
check_eq "source worktree stays clean" "$(git -C "$repo/main" status --porcelain)" ""
arch=$(cd "$repo" && bash "$W" rundir --archive | json_get '["archived"]')
check "archived run dir keeps state" test -f "$arch/state.json"
check "run dir gone after archive" test ! -e "$rd"
(cd "$repo" && bash "$W" rundir --archive >/dev/null 2>&1); rc=$?
check_eq "archive without a run dir: exit 2" "$rc" 2

section "standard layout lifecycle still works (regression)"
rm -r "$std/.agents"
t=$(cd "$std" && bash "$W" create task-one 2>/dev/null | json_get '["worktree_path"]')
check_eq "task worktree at <parent>/worktrees/<repo>/<slug>" "$t" "$WORK/worktrees/std/task-one"
echo change >>"$t/a.txt"
printf 'a.txt\n' >"$WORK/whitelist"
check "check_scope passes for a whitelisted change" bash "$SCRIPTS/check_scope.sh" "$t" "$WORK/whitelist"
git -C "$t" commit -qam "sop(task-one): change"
(cd "$std" && bash "$W" integrate 1 --base HEAD sop/task-one >/dev/null 2>&1); rc=$?
check_eq "integrate exits 0" "$rc" 0
check_eq "status lists task and stage" "$(cd "$std" && bash "$W" status | python3 -c 'import json,sys; print(sorted({json.loads(l)["kind"] for l in sys.stdin}))')" \
  "['stage', 'task']"
(cd "$std" && bash "$W" remove --stage 1 >/dev/null 2>&1 && bash "$W" remove task-one >/dev/null 2>&1); rc=$?
check_eq "remove stage and task" "$rc" 0
check_eq "no spec-ops-pipeline worktrees left" "$(cd "$std" && bash "$W" list)" ""

section "remove --pr-merged"
t=$(cd "$std" && bash "$W" create squashed 2>/dev/null | json_get '["worktree_path"]')
echo squashed >>"$t/a.txt" && git -C "$t" commit -qam squashed
(cd "$std" && bash "$W" remove squashed >/dev/null 2>&1)
check "unmerged branch kept without --pr-merged" git -C "$std" show-ref --verify -q refs/heads/sop/squashed
t=$(cd "$std" && git worktree add -q "$WORK/sq2" sop/squashed && echo "$WORK/sq2")
echo dirty >>"$t/a.txt"
(cd "$std" && bash "$W" remove squashed --pr-merged >/dev/null 2>&1); rc=$?
check_eq "--pr-merged still refuses a dirty worktree" "$rc" 2
git -C "$t" checkout -q -- a.txt
(cd "$std" && bash "$W" remove squashed --pr-merged >/dev/null 2>&1); rc=$?
check_eq "--pr-merged exits 0" "$rc" 0
check "--pr-merged deletes the unmerged branch" bash -c "! git -C '$std' show-ref --verify -q refs/heads/sop/squashed"

section "sync"
sync_json() { (cd "$std" && bash "$W" sync 2>/dev/null); }
out=$(sync_json); rc=$?
check_eq "up to date: exit 0" "$rc" 0
check_eq "up to date: not updated" "$(json_get '["updated"]' <<<"$out")" False
up=$WORK/std.up
echo three >>"$up/a.txt" && git -C "$up" commit -qam three
new=$(git -C "$up" rev-parse HEAD)
echo untracked >"$std/scratch.txt"
out=$(sync_json); rc=$?
check_eq "behind upstream: exit 0" "$rc" 0
check_eq "behind upstream: fast-forwarded" "$(git -C "$std" rev-parse HEAD)" "$new"
check_eq "behind upstream: updated" "$(json_get '["updated"]' <<<"$out")" True
check "untracked files kept" test -f "$std/scratch.txt"
rm "$std/scratch.txt"
echo four >>"$up/a.txt" && git -C "$up" commit -qam four
echo dirty >>"$std/a.txt"
out=$(sync_json); rc=$?
check_eq "tracked changes: exit 1" "$rc" 1
check_eq "tracked changes: reason" "$(json_get '["reason"]' <<<"$out")" "uncommitted changes"
check_eq "tracked changes: HEAD unchanged" "$(git -C "$std" rev-parse HEAD)" "$new"
git -C "$std" checkout -q -- a.txt
echo local >>"$std/b.txt" && git -C "$std" add b.txt && git -C "$std" commit -qm local
out=$(sync_json); rc=$?
check_eq "local commits: exit 1" "$rc" 1
check_eq "local commits: reason" "$(json_get '["reason"]' <<<"$out")" "local commits not on origin"
git -C "$std" reset -q --hard "$new"
git -C "$std" checkout -q --detach
out=$(sync_json); rc=$?
check_eq "detached HEAD: exit 1" "$rc" 1
git -C "$std" checkout -q main
(cd "$std" && bash "$W" sync extra >/dev/null 2>&1); rc=$?
check_eq "sync with an argument: exit 2" "$rc" 2
bare_out=$(cd "$repo" && bash "$W" sync 2>/dev/null); rc=$?
check_eq "bare layout: syncs the default-branch worktree" "$rc" 0
check_eq "bare layout: worktree is main/" "$(json_get '["worktree"]' <<<"$bare_out")" "$repo/main"

section "remove: docker compose down"
# Fake docker: logs "<cwd>|<args>", prints $DOCKER_ROWS for `ps`, exits $DOCKER_DOWN_RC for `compose`.
mkdir -p "$WORK/dockershim"
cat >"$WORK/dockershim/docker" <<'SH'
#!/usr/bin/env bash
# State files: DOCKER_ROWS (ps rows "project<TAB>working_dir"), DOCKER_NETS (JSON array of
# networks: Name, Labels, IPAM), DOCKER_NETC ("network<TAB>container id" attachments),
# DOCKER_POOLS (JSON for `info`, absent = null), DOCKER_COMPOSE_CFG (JSON for `compose config`,
# absent = it fails). DOCKER_INFO_RC / DOCKER_NETRM_RC force failures, DOCKER_INFO_SLEEP a hang.
printf '%s|%s\n' "$PWD" "$*" >>"$DOCKER_LOG"
proj="" net="" quiet=0 fmt=0
for a in "$@"; do
  case $a in
    label=com.docker.compose.project=*) proj=${a#label=com.docker.compose.project=} ;;
    network=*) net=${a#network=} ;;
    -q) quiet=1 ;;
    --format) fmt=1 ;;
  esac
done
case $1 in
  ps)
    if [[ -n $net ]]; then awk -F'\t' -v n="$net" '$1 == n { print $2 }' "$DOCKER_NETC" 2>/dev/null
    elif [[ -n $proj ]]; then awk -F'\t' -v p="$proj" '$1 == p { print "cid" NR }' "$DOCKER_ROWS" 2>/dev/null
    else cat "$DOCKER_ROWS" 2>/dev/null
    fi
    exit 0 ;;
  info)
    [[ -z ${DOCKER_INFO_SLEEP:-} ]] || sleep "$DOCKER_INFO_SLEEP"
    [[ ${DOCKER_INFO_RC:-0} -eq 0 ]] || exit "$DOCKER_INFO_RC"
    cat "$DOCKER_POOLS" 2>/dev/null || echo null ;;
  network)
    case $2 in
      ls)
        [[ ${DOCKER_NETLS_RC:-0} -eq 0 ]] || { echo "ls boom" >&2; exit "$DOCKER_NETLS_RC"; }
        python3 -c 'import json,sys
proj = sys.argv[1]
for n in json.load(open(sys.argv[2])):
    if not proj or (n.get("Labels") or {}).get("com.docker.compose.project") == proj:
        print(n["Name"])' "$proj" "$DOCKER_NETS" ;;
      inspect)
        if [[ ${DOCKER_NETINSPECT_RC:-0} -ne 0 || ( -e $DOCKER_NETS.rmd && -n ${DOCKER_INSPECT_RC_AFTER_RM:-} ) ]]; then
          echo "inspect boom" >&2; exit "${DOCKER_NETINSPECT_RC:-$DOCKER_INSPECT_RC_AFTER_RM}"
        fi
        if [[ -n ${DOCKER_INSPECT_RAW:-} ]]; then printf '%s\n' "$DOCKER_INSPECT_RAW"; else cat "$DOCKER_NETS"; fi ;;
      rm)
        [[ ${DOCKER_NETRM_RC:-0} -eq 0 ]] || exit "$DOCKER_NETRM_RC"
        : >"$DOCKER_NETS.rmd"
        python3 -c 'import json,sys
f = sys.argv[2]
d = [n for n in json.load(open(f)) if n["Name"] != sys.argv[1]]
json.dump(d, open(f, "w"))' "$3" "$DOCKER_NETS" ;;
    esac ;;
  compose)
    if [[ $2 == config ]]; then
      [[ -n ${DOCKER_COMPOSE_CFG:-} && -f $DOCKER_COMPOSE_CFG ]] || exit 1
      cat "$DOCKER_COMPOSE_CFG"; exit 0
    fi
    rc=${DOCKER_DOWN_RC:-0}
    if [[ $rc -eq 0 && $2 == -p ]]; then   # a successful down removes the project's containers
      awk -F'\t' -v p="$3" '$1 != p' "$DOCKER_ROWS" >"$DOCKER_ROWS.tmp" && mv "$DOCKER_ROWS.tmp" "$DOCKER_ROWS"
    fi
    exit "$rc" ;;
esac
SH
chmod +x "$WORK/dockershim/docker"
export DOCKER_LOG=$WORK/docker.log DOCKER_ROWS=$WORK/docker.rows
export DOCKER_NETS=$WORK/docker.nets DOCKER_NETC=$WORK/docker.netc DOCKER_POOLS=$WORK/docker.pools
echo '[]' >"$DOCKER_NETS"
dremove() { (cd "$repo" && PATH="$WORK/dockershim:$PATH" bash "$W" remove "$@"); }
new_task() { (cd "$repo" && bash "$W" create "$1" 2>/dev/null | json_get '["worktree_path"]'); }

t=$(new_task compose-own)
printf 'compose-own\t%s\ncompose-own\t%s/svc\nother\t%s/main\n' "$t" "$t" "$repo" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
dremove compose-own >/dev/null 2>&1; rc=$?
check_eq "remove with own compose project exits 0" "$rc" 0
check_eq "down run once, in the project's dir, without -v" "$(grep -c '|compose' "$DOCKER_LOG")" 1
check "down targets the project" grep -qxF "$t|compose -p compose-own down" "$DOCKER_LOG"
check "worktree removed" test ! -e "$t"

t=$(new_task compose-shared)
printf 'shared\t%s\nshared\t%s/main\n' "$t" "$repo" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
err=$(dremove compose-shared 2>&1 >/dev/null)
check "shared project: no down" test "$(grep -c '|compose' "$DOCKER_LOG")" -eq 0
check "shared project: reported as left running" grep -q "left running" <<<"$err"
check "shared project: worktree still removed" test ! -e "$t"

t=$(new_task compose-off)
printf 'off\t%s\n' "$t" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
SOP_COMPOSE_DOWN=0 dremove compose-off >/dev/null 2>&1
check_eq "SOP_COMPOSE_DOWN=0: docker not called" "$(wc -l <"$DOCKER_LOG")" 0

t=$(new_task compose-dirty)
printf 'dirty\t%s\n' "$t" >"$DOCKER_ROWS"
echo change >>"$t/a.txt"
: >"$DOCKER_LOG"
dremove compose-dirty >/dev/null 2>&1; rc=$?
check_eq "dirty worktree refused" "$rc" 2
check_eq "dirty worktree: docker not called" "$(wc -l <"$DOCKER_LOG")" 0

printf 'dirty\t%s\n' "$t" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
DOCKER_DOWN_RC=1 dremove compose-dirty --force >/dev/null 2>&1; rc=$?
check_eq "failed down does not block remove" "$rc" 0
check "failed down: down was attempted" grep -q '|compose -p dirty down' "$DOCKER_LOG"
check "failed down: worktree removed" test ! -e "$t"

section "remove: reclaim networks"
# net_json <name> <project|-> [subnet]  ->  one network object
net_json() {
  python3 -c 'import json,sys
n, p, s = sys.argv[1:4]
o = {"Name": n, "Labels": {"com.docker.compose.project": p} if p != "-" else {},
     "IPAM": {"Config": [{"Subnet": s}] if s else None}}
print(json.dumps(o))' "$1" "$2" "${3:-}"
}
set_nets() { local IFS=,; echo "[$*]" >"$DOCKER_NETS"; }
net_exists() { grep -q "\"Name\": \"$1\"" "$DOCKER_NETS"; }
rm_count() { grep -c '|network rm' "$DOCKER_LOG" || true; }
: >"$DOCKER_NETC"

# Root-level compose file: project name is the worktree dir name; `run --rm` left only a network.
t=$(new_task reclaim-own)
: >"$DOCKER_ROWS"
set_nets "$(net_json reclaim-own_default reclaim-own 172.20.0.0/16)" "$(net_json unrelated_default unrelated 172.21.0.0/16)"
: >"$DOCKER_LOG"
err=$(dremove reclaim-own 2>&1 >/dev/null)
check "reclaim: own network removed" test ! -e "$t" -a "$(rm_count)" -eq 1
check "reclaim: own network gone from daemon" bash -c "! grep -q reclaim-own_default '$DOCKER_NETS'"
check "reclaim: message printed" grep -qxF "removed network: reclaim-own_default" <<<"$err"
check "reclaim: other project's network kept" grep -q unrelated_default "$DOCKER_NETS"

# A project with a container elsewhere keeps its networks.
t=$(new_task reclaim-shared)
printf 'reclaim-shared\t%s/main\n' "$repo" >"$DOCKER_ROWS"
set_nets "$(net_json reclaim-shared_default reclaim-shared 172.20.0.0/16)"
: >"$DOCKER_LOG"
dremove reclaim-shared >/dev/null 2>&1
check "reclaim: project with a container elsewhere kept" test "$(rm_count)" -eq 0
check "reclaim: shared network still present" grep -q reclaim-shared_default "$DOCKER_NETS"

# A stopped non-compose container is still attached.
t=$(new_task reclaim-stopped)
: >"$DOCKER_ROWS"
set_nets "$(net_json reclaim-stopped_default reclaim-stopped 172.20.0.0/16)"
printf 'reclaim-stopped_default\tabc123\n' >"$DOCKER_NETC"
: >"$DOCKER_LOG"
dremove reclaim-stopped >/dev/null 2>&1
check "reclaim: network with a stopped non-compose container kept" test "$(rm_count)" -eq 0
: >"$DOCKER_NETC"

# SOP_COMPOSE_DOWN=0 disables the reclaim too.
t=$(new_task reclaim-off)
: >"$DOCKER_ROWS"
set_nets "$(net_json reclaim-off_default reclaim-off 172.20.0.0/16)"
: >"$DOCKER_LOG"
SOP_COMPOSE_DOWN=0 dremove reclaim-off >/dev/null 2>&1
check "reclaim: SOP_COMPOSE_DOWN=0 no network rm" test "$(rm_count)" -eq 0

# A project compose_down just stopped (named differently from the directory) is reclaimed too.
t=$(new_task reclaim-named)
printf 'custom\t%s\n' "$t" >"$DOCKER_ROWS"
set_nets "$(net_json custom_default custom 172.20.0.0/16)"
: >"$DOCKER_LOG"
dremove reclaim-named >/dev/null 2>&1
check "reclaim: stopped project's network removed" bash -c "! grep -q custom_default '$DOCKER_NETS'"

# A failed rm is only a warning.
t=$(new_task reclaim-fail)
: >"$DOCKER_ROWS"
set_nets "$(net_json reclaim-fail_default reclaim-fail 172.20.0.0/16)"
DOCKER_NETRM_RC=1 dremove reclaim-fail >/dev/null 2>&1; rc=$?
check_eq "reclaim: failed network rm is not fatal" "$rc" 0
check "reclaim: worktree removed despite failed rm" test ! -e "$t"

# A root compose file whose project name is overridden (`name:` / COMPOSE_PROJECT_NAME in .env):
# the name `docker compose config` resolves is reclaimed too.
t=$(new_task reclaim-cfgname)
echo 'services: {}' >"$t/compose.yaml"
git -C "$t" add compose.yaml && git -C "$t" commit -qm compose
echo '{"name": "myapp-dev", "networks": {"default": {"name": "myapp-dev_default"}}}' >"$WORK/compose.cfg"
: >"$DOCKER_ROWS"
set_nets "$(net_json myapp-dev_default myapp-dev 172.20.0.0/16)" "$(net_json keep_default keep 172.21.0.0/16)"
: >"$DOCKER_LOG"
DOCKER_COMPOSE_CFG=$WORK/compose.cfg dremove reclaim-cfgname >/dev/null 2>&1
check "reclaim: compose config ran in the worktree" grep -qF "$t|compose config --format json" "$DOCKER_LOG"
check "reclaim: overridden project name's network removed" bash -c "! grep -q myapp-dev_default '$DOCKER_NETS'"
check "reclaim: unrelated orphan left to pool --prune" grep -q keep_default "$DOCKER_NETS"
# Without a root compose file no `compose config` is run.
t=$(new_task reclaim-nocompose)
: >"$DOCKER_LOG"
DOCKER_COMPOSE_CFG=$WORK/compose.cfg dremove reclaim-nocompose >/dev/null 2>&1
check_eq "reclaim: no compose file, no compose config" "$(grep -c '|compose config' "$DOCKER_LOG" || true)" 0

# Directory-name normalisation: stage worktrees are named _stage-<id> -> project stage-<id>.
t=$(cd "$std" && bash "$W" create reclaim-stagebr 2>/dev/null | json_get '["worktree_path"]')
git -C "$t" commit --allow-empty -qm x
(cd "$std" && bash "$W" integrate 9 --base HEAD sop/reclaim-stagebr >/dev/null 2>&1)
set_nets "$(net_json stage-9_default stage-9 172.20.0.0/16)"
: >"$DOCKER_ROWS"; : >"$DOCKER_LOG"
(cd "$std" && PATH="$WORK/dockershim:$PATH" bash "$W" remove --stage 9 >/dev/null 2>&1)
check "reclaim: _stage-9 maps to project stage-9" bash -c "! grep -q stage-9_default '$DOCKER_NETS'"
(cd "$std" && PATH="$WORK/dockershim:$PATH" bash "$W" remove reclaim-stagebr --force >/dev/null 2>&1)

section "pool"
pool() { (cd "$repo" && PATH="$WORK/dockershim:$PATH" bash "$W" pool "$@"); }
pjson() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1], {"d": d})))' "$1"; }
: >"$DOCKER_ROWS"; : >"$DOCKER_NETC"; rm -f "$DOCKER_POOLS"

set_nets "$(net_json bridge - 172.17.0.0/16)" "$(net_json host - '')" "$(net_json none - '')" \
  "$(net_json v6only - 'fd00::/64')"
out=$(pool); rc=$?
check_eq "pool: exit 0" "$rc" 0
check_eq "pool: default pools total 31" "$(pjson 'd["total"]' <<<"$out")" 31
check_eq "pool: default pools source" "$(pjson 'd["pools_from"]' <<<"$out")" '"default"'
check_eq "pool: null IPAM ignored (bridge only, v6 ignored)" "$(pjson 'd["used"]' <<<"$out")" 1
check_eq "pool: free = total - used" "$(pjson 'd["free"]' <<<"$out")" 30

# A /20 inside 192.168.0.0/16 uses one slot; a /12 inside 172.16/12 covers 15 slots (172.17-31).
set_nets "$(net_json a - 192.168.16.0/24)" "$(net_json b - 192.168.16.128/25)" "$(net_json c - 172.16.0.0/12)"
out=$(pool)
check_eq "pool: overlapping subnets counted per slot" "$(pjson 'd["used"]' <<<"$out")" 16

# Daemon pools: 10.0.0.0/8 at /24 = 65536 slots plus 172.30.0.0/16 at /24 = 256.
echo '[{"Base":"10.0.0.0/8","Size":24},{"Base":"172.30.0.0/16","Size":24}]' >"$DOCKER_POOLS"
set_nets "$(net_json a - 10.1.2.0/24)" "$(net_json b - 10.1.2.0/23)" "$(net_json c - 172.30.5.0/25)"
out=$(pool)
check_eq "pool: daemon pools" "$(pjson '[d["pools_from"], d["total"], d["used"], d["free"]]' <<<"$out")" '["daemon", 65792, 3, 65789]'
rm -f "$DOCKER_POOLS"

# Orphans and prune.
set_nets "$(net_json bridge - 172.17.0.0/16)" \
  "$(net_json orph_default orph 172.20.0.0/16)" \
  "$(net_json live_default live 172.21.0.0/16)" \
  "$(net_json held_default held 172.22.0.0/16)" \
  "$(net_json attached_default att 172.23.0.0/16)" \
  "$(net_json plain - 172.24.0.0/16)"
printf 'live\t/somewhere\n' >"$DOCKER_ROWS"
printf 'attached_default\tdeadbeef\n' >"$DOCKER_NETC"
: >"$DOCKER_LOG"
out=$(pool)
check_eq "pool: orphans sorted, only truly unused" "$(pjson 'd["orphans"]' <<<"$out")" '["held_default", "orph_default"]'
check_eq "pool: no prune: pruned empty" "$(pjson 'd["pruned"]' <<<"$out")" '[]'
check_eq "pool: read-only without --prune" "$(rm_count)" 0
out=$(pool --prune 2>/dev/null)
check_eq "pool: prune removes only orphans" "$(pjson '[d["pruned"], d["used"]]' <<<"$out")" '[["held_default", "orph_default"], 4]'
check "pool: live, attached and unlabelled kept" bash -c "grep -q live_default '$DOCKER_NETS' && grep -q attached_default '$DOCKER_NETS' && grep -q '\"plain\"' '$DOCKER_NETS'"
set_nets "$(net_json a_default a 172.20.0.0/16)" "$(net_json b_default b 172.21.0.0/16)"
: >"$DOCKER_ROWS"; : >"$DOCKER_NETC"
out=$(pool --project a)
check_eq "pool --project: orphans limited, no per_worktree" "$(pjson '[d["orphans"], "per_worktree" in d]' <<<"$out")" '[["a_default"], false]'

# per_worktree: non-external networks of the source worktree's root compose file.
out=$(pool)
check_eq "pool: no root compose file -> per_worktree 0" "$(pjson 'd["per_worktree"]' <<<"$out")" 0
src=$(cd "$repo" && bash "$W" config | json_get '["source_worktree"]')
echo 'services: {}' >"$src/compose.yaml"
echo '{"name": "x", "networks": {"default": {}, "back": {}, "ext": {"external": true}}}' >"$WORK/compose.cfg"
out=$(DOCKER_COMPOSE_CFG=$WORK/compose.cfg pool)
check_eq "pool: per_worktree counts non-external networks" "$(pjson 'd["per_worktree"]' <<<"$out")" 2
out=$(pool)
check_eq "pool: compose config fails -> per_worktree null" "$(pjson 'd["per_worktree"]' <<<"$out")" null
rm "$src/compose.yaml"

out=$(DOCKER_INFO_SLEEP=3 SOP_DOCKER_TIMEOUT=1 pool); rc=$?
check_eq "pool: hung daemon -> docker false" "$rc $(pjson '[d["docker"], d["reason"]]' <<<"$out")" '0 [false, "docker daemon not responding"]'

# Unreachable daemon and absent docker.
out=$(DOCKER_INFO_RC=1 pool); rc=$?
check_eq "pool: daemon unreachable" "$rc $(pjson '[d["docker"]]' <<<"$out")" '0 [false]'
nobin=$WORK/nodocker; mkdir -p "$nobin"
for c in git bash python3 awk sed sort grep cat dirname basename readlink mkdir env tr head cut uname date rm cp ls id wc mktemp find xargs mv sleep tail printf sha1sum; do
  command -v "$c" >/dev/null && ln -sf "$(command -v "$c")" "$nobin/$c"
done
out=$(cd "$repo" && PATH="$nobin" bash "$W" pool); rc=$?
check_eq "pool: docker absent" "$rc $(pjson '[d["docker"]]' <<<"$out")" '0 [false]'
(pool --bogus >/dev/null 2>&1); rc=$?
check_eq "pool: bad argument exit 2" "$rc" 2

# Unreadable or invalid Docker data -> error form (exit 0, no counts, no traceback).
perr() { pool "$@" 2>"$WORK/pool.err"; }
no_tb() { ! grep -q Traceback "$WORK/pool.err"; }
set_nets "$(net_json bridge - 172.17.0.0/16)"
out=$(DOCKER_NETLS_RC=1 perr); rc=$?
check_eq "pool: ls fails -> error form" "$rc $(pjson '[d["docker"], d["error"], d["pruned"], "total" in d]' <<<"$out")" '0 [true, "docker network ls failed: ls boom", [], false]'
out=$(DOCKER_NETINSPECT_RC=1 perr); rc=$?
check_eq "pool: inspect fails -> error form" "$rc $(pjson '[d["error"], sorted(d)]' <<<"$out")" '0 ["docker network inspect failed: inspect boom", ["docker", "error", "pruned"]]'
for raw in 'not json' '{"a":1}' '[1]'; do
  out=$(DOCKER_INSPECT_RAW=$raw perr); rc=$?
  check_eq "pool: inspect output '$raw' -> error form" "$rc $(pjson '["error" in d, "used" in d]' <<<"$out")" '0 [true, false]'
  check "pool: inspect output '$raw': no traceback" no_tb
done
# Pool validation.
set_nets "$(net_json n1 - 10.1.0.0/24)"
echo '[{"Base":"bogus","Size":24},{"Base":"10.0.0.0/8","Size":24},{"Base":"10.0.0.0/8","Size":"x"},"x",{"Base":"10.0.0.0/16","Size":8}]' >"$DOCKER_POOLS"
out=$(perr); rc=$?
check_eq "pool: invalid entries skipped" "$rc $(pjson '[d["pools_from"], d["total"], d["used"]]' <<<"$out")" '0 ["daemon", 65536, 1]'
check_eq "pool: one stderr line per invalid entry" "$(grep -c 'ignoring invalid default-address-pools entry' "$WORK/pool.err")" 4
check "pool: invalid entries: no traceback" no_tb
for raw in '[{"Base":"bogus","Size":24}]' '["10.0.0.0/8"]' '{"Base":"10.0.0.0/8"}' '[{"Base":"fd00::/8","Size":64}]' '5'; do
  echo "$raw" >"$DOCKER_POOLS"
  : >"$DOCKER_LOG"
  out=$(perr --prune); rc=$?
  check_eq "pool: no valid pool '$raw' -> error" "$rc $(pjson '[d["error"], d["pruned"], "total" in d]' <<<"$out")" '0 ["no valid default-address-pools entry", [], false]'
  check "pool: no valid pool '$raw': no traceback, nothing pruned" bash -c "[[ \$(grep -c '|network rm' '$DOCKER_LOG' || true) == 0 ]] && ! grep -q Traceback '$WORK/pool.err'"
done
echo '[]' >"$DOCKER_POOLS"
out=$(perr)
check_eq "pool: empty pool list -> defaults" "$(pjson 'd["pools_from"]' <<<"$out")" '"default"'
rm -f "$DOCKER_POOLS"
# Prune: discovery failure removes nothing; recount failure reports what was removed.
set_nets "$(net_json bridge - 172.17.0.0/16)" "$(net_json orph_default orph 172.20.0.0/16)"
: >"$DOCKER_LOG"; rm -f "$DOCKER_NETS.rmd"
out=$(DOCKER_NETLS_RC=1 perr --prune); rc=$?
check_eq "pool --prune: discovery fails -> error, nothing removed" "$rc $(pjson '[d["pruned"]]' <<<"$out") $(rm_count)" '0 [[]] 0'
out=$(DOCKER_INSPECT_RC_AFTER_RM=1 perr --prune 2>/dev/null); rc=$?
check_eq "pool --prune: recount fails -> error with pruned" "$rc $(pjson '[d["error"], d["pruned"], "used" in d]' <<<"$out")" '0 ["docker network inspect failed: inspect boom", ["orph_default"], false]'
rm -f "$DOCKER_NETS.rmd"

section "usage"
out=$(cd "$repo" && bash "$W" 2>&1 >/dev/null); rc=$?
check_eq "usage: no args exit 2" "$rc" 2
printf '%s\n' "$out" >"$WORK/usage.out"
check "usage: no args lists sync and pool entries" bash -c "grep -q 'worktree.sh sync' '$WORK/usage.out' && grep -q 'worktree.sh pool' '$WORK/usage.out' && grep -q '^Usage:' '$WORK/usage.out'"
check "usage: no args stops before Built-in defaults" bash -c "! grep -q 'Built-in defaults' '$WORK/usage.out'"
check "usage: --help prints full header" bash -c "bash '$W' --help | grep -q 'Built-in defaults'"

finish
