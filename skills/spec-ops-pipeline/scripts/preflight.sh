#!/usr/bin/env bash
# One-call Lead preflight: runs the step 0 checks and prints ONE compact JSON line.
#
# Usage: preflight.sh --agent claude|gemini|codex [--fetch]
#
# Output keys:
#   runtime     detect_runtime.sh --agent X
#   config      worktree.sh config
#   leftovers   worktree.sh status, one object per task/stage worktree
#   run         worktree.sh rundir
#   pr          pr.sh preflight
#   baseline    exact output of `git status --porcelain=v1 && git diff HEAD | sha256sum`
#               run in config.source_worktree (the step 0 baseline command)
#   base_check  {"default_base","head","base","match"}: HEAD vs default_base in source_worktree
#   docker_pool worktree.sh pool (read-only)
# --fetch: `git fetch` the remote of default_base first when it is a remote ref.
# A failing sub-call becomes {"error":"<first stderr line>"} under its key; the JSON is
# always printed. Exit: 0 = printed, 2 = usage error.
set -euo pipefail

die() { printf 'preflight: %s\n' "$*" >&2; exit 2; }

agent="" fetch=0
while (($#)); do
  case $1 in
    --agent) (($# >= 2)) || die "--agent needs a value"; agent=$2; shift 2 ;;
    --fetch) fetch=1; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case $agent in claude|gemini|codex) ;; *) die "--agent claude|gemini|codex is required" ;; esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sop-preflight.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# run <key> <cmd>...: stdout -> $tmp/<key>.out, first stderr line + exit code kept.
run() {
  local key=$1; shift
  local rc=0
  "$@" >"$tmp/$key.out" 2>"$tmp/$key.err" || rc=$?
  printf '%s' "$rc" >"$tmp/$key.rc"
}

run runtime bash "$here/detect_runtime.sh" --agent "$agent"
run config bash "$here/worktree.sh" config
run leftovers bash "$here/worktree.sh" status
run run bash "$here/worktree.sh" rundir
run pr bash "$here/pr.sh" preflight
run pool bash "$here/worktree.sh" pool

# Source worktree from the config JSON (empty when config failed).
cfg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$tmp/config.out" "$1" 2>/dev/null || true; }
src=$(cfg source_worktree)
base=$(cfg default_base)
if [[ -n $src && -d $src ]]; then
  if ((fetch)) && [[ -n $base && $base != HEAD ]]; then
    full=$(git -C "$src" rev-parse --symbolic-full-name "$base" 2>/dev/null || true)
    if [[ $full == refs/remotes/* ]]; then
      remote=${full#refs/remotes/}; remote=${remote%%/*}
      git -C "$src" fetch -q "$remote" >/dev/null 2>"$tmp/fetch.err" || printf 'fetch failed' >"$tmp/fetch.fail"
    fi
  fi
  rc=0
  (cd "$src" && git status --porcelain=v1 && git diff HEAD | sha256sum) >"$tmp/baseline.out" 2>"$tmp/baseline.err" || rc=$?
  printf '%s' "$rc" >"$tmp/baseline.rc"
  git -C "$src" rev-parse HEAD >"$tmp/head.out" 2>"$tmp/head.err" || true
  [[ -n $base ]] && { git -C "$src" rev-parse "$base^{commit}" >"$tmp/base.out" 2>"$tmp/base.err" || true; }
fi

python3 - "$tmp" "$base" <<'PY'
import json, os, sys
tmp, default_base = sys.argv[1], sys.argv[2]

def rd(name):
    try:
        with open(os.path.join(tmp, name), newline="", encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except OSError:
        return None

def err(key, fallback):
    first = (rd(key + ".err") or "").strip().splitlines()
    return {"error": first[0] if first else fallback}

def one(key):
    out, rc = rd(key + ".out") or "", rd(key + ".rc")
    try:
        return json.loads(out)
    except ValueError:
        return err(key, "no JSON output (exit %s)" % rc)

def lines(key):
    res = []
    for ln in (rd(key + ".out") or "").splitlines():
        if ln.strip():
            try:
                res.append(json.loads(ln))
            except ValueError:
                res.append({"error": ln})
    if not res and rd(key + ".rc") not in (None, "0"):
        return [err(key, "failed")]
    return res

head = (rd("head.out") or "").strip()
base = (rd("base.out") or "").strip()
baseline = rd("baseline.out")
if baseline is None or rd("baseline.rc") not in (None, "0"):
    baseline_val = err("baseline", "source_worktree unavailable")
else:
    baseline_val = baseline
out = {
    "runtime": one("runtime"),
    "config": one("config"),
    "leftovers": lines("leftovers"),
    "run": one("run"),
    "pr": one("pr"),
    "baseline": baseline_val,
    "base_check": {"default_base": default_base or None, "head": head or None,
                   "base": base or None, "match": bool(head) and head == base},
    "docker_pool": one("pool"),
}
bc = out["base_check"]
if rd("fetch.fail") is not None:
    first = (rd("fetch.err") or "").strip().splitlines()
    bc["fetch_error"] = first[0] if first else "git fetch failed"
if default_base and not base:
    first = (rd("base.err") or "").strip().splitlines()
    bc["error"] = first[0] if first else "default_base does not resolve"
print(json.dumps(out, separators=(",", ":")))
PY
