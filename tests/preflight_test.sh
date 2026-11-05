#!/usr/bin/env bash
# Tests for preflight.sh.  Run: bash tests/preflight_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=$SCRIPTS/preflight.sh

# Shims: no docker, no gh (and no network) so nothing real is called.
mkdir -p "$WORK/nobin"
for c in docker gh; do
  printf '#!/usr/bin/env bash\necho "%s: not available" >&2\nexit 127\n' "$c" >"$WORK/nobin/$c"
  chmod +x "$WORK/nobin/$c"
done
pf() { local dir=$1; shift; (cd "$dir" && PATH="$WORK/nobin:$PATH" bash "$P" "$@"); }

repo=$(make_repo std)
echo dirty >>"$repo/a.txt"
echo new >"$repo/untracked.txt"

section "keys and shape"
out=$(pf "$repo" --agent claude 2>/dev/null); rc=$?
check_eq "exit 0" "$rc" 0
check_eq "single line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
check "valid JSON with all keys" python3 -c '
import json,sys
d=json.loads(sys.argv[1])
need={"runtime","config","leftovers","run","pr","baseline","base_check","docker_pool"}
assert need <= d.keys(), d.keys()
assert isinstance(d["leftovers"], list)
assert d["runtime"]["ecosystem"] == "claude"' "$out"

section "baseline"
(cd "$repo" && git status --porcelain=v1 && git diff HEAD | sha256sum) >"$WORK/want.txt"
printf '%s' "$out" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["baseline"])' >"$WORK/got.txt"
check "baseline is byte-identical to the command output" cmp "$WORK/want.txt" "$WORK/got.txt"
check "baseline mentions the dirty file" grep -q ' M a.txt' "$WORK/got.txt"

section "base_check"
check_eq "HEAD base matches" "$(printf '%s' "$out" | json_get '["base_check"]["match"]')" True
mk_remote_case() {
  git -C "$repo" branch -q other HEAD~1
  printf '{"defaultBase":"other"}' >"$WORK/cfg.json"
}
mk_remote_case
out2=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude 2>/dev/null)
check_eq "default_base = other" "$(printf '%s' "$out2" | json_get '["base_check"]["default_base"]')" other
check_eq "HEAD != other -> match false" "$(printf '%s' "$out2" | json_get '["base_check"]["match"]')" False
printf '{"defaultBase":"main"}' >"$WORK/cfg.json"
out3=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude 2>/dev/null)
check_eq "HEAD == main -> match true" "$(printf '%s' "$out3" | json_get '["base_check"]["match"]')" True
printf '{"defaultBase":"origin/main"}' >"$WORK/cfg.json"
out4=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude --fetch 2>/dev/null); rc=$?
check_eq "--fetch on a remote base exits 0" "$rc" 0
check_eq "origin/main matches" "$(printf '%s' "$out4" | json_get '["base_check"]["match"]')" True
check_eq "healthy: no error key" "$(printf '%s' "$out4" | json_get '["base_check"].get("error")')" None
check_eq "healthy: no fetch_error key" "$(printf '%s' "$out4" | json_get '["base_check"].get("fetch_error")')" None
printf '{"defaultBase":"no-such-ref"}' >"$WORK/cfg.json"
out_e=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude 2>/dev/null); rc=$?
check_eq "unresolvable base exits 0" "$rc" 0
check_eq "unresolvable base -> match false" "$(printf '%s' "$out_e" | json_get '["base_check"]["match"]')" False
check_eq "unresolvable base -> error set" "$(printf '%s' "$out_e" | json_get '["base_check"]["error"] != ""')" True
check_eq "unresolvable base -> no fetch_error" "$(printf '%s' "$out_e" | json_get '["base_check"].get("fetch_error")')" None
printf '{"defaultBase":"origin/main"}' >"$WORK/cfg.json"

section "--fetch really fetches"
git -C "$WORK/std.up" commit -q --allow-empty -m three
newsha=$(git -C "$WORK/std.up" rev-parse HEAD)
out5=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude 2>/dev/null)
check_eq "no --fetch: base unchanged" "$([[ $(printf '%s' "$out5" | json_get '["base_check"]["base"]') == "$newsha" ]] && echo moved || echo same)" same
out6=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude --fetch 2>/dev/null)
check_eq "--fetch: base moved to the upstream commit" "$(printf '%s' "$out6" | json_get '["base_check"]["base"]')" "$newsha"

section "--fetch failure -> fetch_error"
orig_url=$(git -C "$repo" remote get-url origin)
git -C "$repo" remote set-url origin "$WORK/no-such-remote.git"
out_f=$(cd "$repo" && SOP_CONFIG=$WORK/cfg.json PATH="$WORK/nobin:$PATH" bash "$P" --agent claude --fetch 2>/dev/null); rc=$?
git -C "$repo" remote set-url origin "$orig_url"
check_eq "failed fetch exits 0" "$rc" 0
check_eq "failed fetch -> fetch_error set" "$(printf '%s' "$out_f" | json_get '["base_check"].get("fetch_error") is not None')" True
check_eq "failed fetch -> no error key" "$(printf '%s' "$out_f" | json_get '["base_check"].get("error")')" None

section "failing sub-calls become errors"
mkdir -p "$WORK/nogit"
out7=$(cd "$WORK/nogit" && GIT_CEILING_DIRECTORIES=$WORK PATH="$WORK/nobin:$PATH" bash "$P" --agent claude 2>/dev/null); rc=$?
check_eq "exit 0 outside a repo" "$rc" 0
check_eq "config has error" "$(printf '%s' "$out7" | json_get '["config"].__contains__("error")')" True
check_eq "baseline has error" "$(printf '%s' "$out7" | json_get '["baseline"].__contains__("error")')" True
check_eq "runtime still fine" "$(printf '%s' "$out7" | json_get '["runtime"]["ecosystem"]')" claude

section "docker and gh absent"
check_eq "docker_pool is valid (docker false)" "$(printf '%s' "$out" | json_get '["docker_pool"]["docker"]')" False
check_eq "pr.ok false" "$(printf '%s' "$out" | json_get '["pr"]["ok"]')" False

section "usage errors"
pf "$repo" --agent claude --bogus >/dev/null 2>&1; check_eq "unknown argument" "$?" 2
pf "$repo" >/dev/null 2>&1; check_eq "missing --agent" "$?" 2
pf "$repo" --agent nope >/dev/null 2>&1; check_eq "bad agent" "$?" 2
pf "$repo" --agent >/dev/null 2>&1; check_eq "--agent without value" "$?" 2

finish
