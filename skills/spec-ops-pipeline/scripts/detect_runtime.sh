#!/usr/bin/env bash
# Detect the agent ecosystem and resolve Lead / Worker model assignments.
#
# Usage: detect_runtime.sh [--agent claude|gemini|codex]
#
# Detection priority (first hit wins):
#   1. --agent flag            (the running agent knows who it is; most reliable)
#   2. SOP_ECOSYSTEM env var   (user override)
#   3. Runtime markers         (env vars injected by the agent CLI itself)
#   4. Fallback                (claude; provider API keys are deliberately not read)
#
# Roles: the main thread (Orchestrator) runs on "worker" across all steps; "lead" runs
# high-reasoning read-only subagents — Planner (step 1-2 audit, gap report, plan & specs),
# Plan Critic (step 2 adversarial spec review), and Reviewer of a Worker's diff (step 5);
# "worker" also implements standard tasks; "worker_light" implements small mechanical
# L-risk tasks; "scout" sweeps code read-only during the audit.
# Per-field overrides: SOP_LEAD_MODEL, SOP_LEAD_EFFORT, SOP_WORKER_MODEL, SOP_WORKER_EFFORT,
# SOP_WORKER_LIGHT_MODEL, SOP_WORKER_LIGHT_EFFORT, SOP_SCOUT_MODEL, SOP_SCOUT_EFFORT.
# Gemini profile: the `model` key of ~/.gemini/antigravity-cli/settings.json (display name or
# id) picks gemini-3.8-flash (Gemini 3.8 Flash...), claude (Claude...), gemini-4-hydrogen
# (Gemini 4 Hydrogen...), or gemini-4 (default, also for Gemini 4 Argon... or any unrecognised
# model or missing file); reported in detected_by as model:<profile>(settings|default).
# Session split: SOP_SESSION_SPLIT = never (default: continue in the same session at phase 2),
# always (fresh session for phase 2), or auto (split with an H-risk task, 3+ tasks, or staged
# mode); reported as "session_split".
# Output: a single JSON object on stdout.
set -euo pipefail

readonly VALID_ECOSYSTEMS="claude gemini codex"

die() { printf 'detect_runtime: %s\n' "$*" >&2; exit 2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

is_valid_ecosystem() { [[ " $VALID_ECOSYSTEMS " == *" $1 "* ]]; }

has_env_prefix() {
  # Succeeds if any exported variable name matches the ERE (anchored at name start).
  compgen -e | grep -Eq "^($1)"
}

gemini_configured_model() {
  local settings="$HOME/.gemini/antigravity-cli/settings.json"
  [[ -r $settings ]] || return 0
  # First `"model": "..."` string; never fails the script.
  awk '/^[[:space:]]*"model"[[:space:]]*:[[:space:]]*"/{sub(/^[^:]*:[[:space:]]*"/, ""); sub(/".*$/, ""); print; exit}' "$settings" 2>/dev/null || true
}

agent_flag=""
while (($#)); do
  case $1 in
    --agent) [[ $# -ge 2 ]] || die "--agent needs a value"; agent_flag=$2; shift 2 ;;
    --agent=*) agent_flag=${1#*=}; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

session_split=${SOP_SESSION_SPLIT:-never}
case $session_split in
  auto|always|never) ;;
  *) die "SOP_SESSION_SPLIT must be one of: auto always never" ;;
esac

ecosystem="" detected_by=""
if [[ -n $agent_flag ]]; then
  is_valid_ecosystem "$agent_flag" || die "--agent must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$agent_flag detected_by="flag:--agent"
elif [[ -n ${SOP_ECOSYSTEM:-} ]]; then
  is_valid_ecosystem "$SOP_ECOSYSTEM" || die "SOP_ECOSYSTEM must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$SOP_ECOSYSTEM detected_by="env:SOP_ECOSYSTEM"
elif [[ -n ${CLAUDECODE:-} ]] || has_env_prefix 'CLAUDE_CODE_'; then
  ecosystem=claude detected_by="runtime:claude-code"
elif has_env_prefix 'CODEX_(SANDBOX|THREAD_ID|SESSION|MANAGED)'; then
  ecosystem=codex detected_by="runtime:codex"
elif has_env_prefix 'ANTIGRAVITY_|AGY_|JETSKI|GEMINI_CLI'; then
  ecosystem=gemini detected_by="runtime:antigravity-or-gemini-cli"
else
  ecosystem=claude detected_by="fallback"
fi

case $ecosystem in
  claude)
    lead_model=claude-opus-5-5   lead_effort=high   lead_alias=opus
    worker_model=claude-sonnet-5-5 worker_effort=medium
    worker_alias=sonnet
    light_model=claude-haiku-5-5   light_effort=medium light_alias=haiku
    scout_model=claude-haiku-5-5   scout_effort=medium scout_alias=haiku ;;
  gemini)
    # Antigravity encodes effort in the model id (see `agy models`).
    gemini_source=default
    gemini_cfg=$(gemini_configured_model | tr '[:upper:]' '[:lower:]')
    case $gemini_cfg in
      "gemini 3.8 flash"*|gemini-3.8-flash*)   gemini_profile=gemini-3.8-flash  gemini_source=settings ;;
      "claude"*|claude-*)                      gemini_profile=claude            gemini_source=settings ;;
      "gemini 4 hydrogen"*|gemini-4-hydrogen*) gemini_profile=gemini-4-hydrogen gemini_source=settings ;;
      "gemini 4"*|gemini-4-*)                  gemini_profile=gemini-4          gemini_source=settings ;;
      *)                                       gemini_profile=gemini-4 ;;
    esac
    case $gemini_profile in
      gemini-3.8-flash)
        lead_model=gemini-3.8-flash-high     lead_effort=high
        worker_model=gemini-3.8-flash-medium worker_effort=medium ;;
      claude)
        lead_model=claude-opus-5-5-high      lead_effort=high
        worker_model=claude-sonnet-5-5-medium worker_effort=medium ;;
      gemini-4-hydrogen)
        lead_model=gemini-4-hydrogen-high    lead_effort=high
        worker_model=gemini-4-hydrogen-high  worker_effort=high ;;
      *)
        lead_model=gemini-4-argon-high       lead_effort=high
        worker_model=gemini-4-hydrogen-high  worker_effort=high ;;
    esac
    lead_alias=$lead_model
    worker_alias=$worker_model
    light_model=$worker_model light_effort=$worker_effort light_alias=$worker_alias
    scout_model=$worker_model scout_effort=$worker_effort scout_alias=$worker_alias
    detected_by+=";model:$gemini_profile($gemini_source)" ;;
  codex)
    lead_model=gpt-6-astra   lead_effort=high     lead_alias=$lead_model
    worker_model=gpt-6.1-sol worker_effort=medium worker_alias=$worker_model
    light_model=gpt-6-luna   light_effort=medium  light_alias=$light_model
    scout_model=gpt-6-luna   scout_effort=medium  scout_alias=$scout_model ;;
esac

lead_model=${SOP_LEAD_MODEL:-$lead_model}
lead_effort=${SOP_LEAD_EFFORT:-$lead_effort}
[[ -n ${SOP_LEAD_MODEL:-} ]] && lead_alias=$SOP_LEAD_MODEL
worker_model=${SOP_WORKER_MODEL:-$worker_model}
worker_effort=${SOP_WORKER_EFFORT:-$worker_effort}
[[ -n ${SOP_WORKER_MODEL:-} ]] && worker_alias=$SOP_WORKER_MODEL
light_model=${SOP_WORKER_LIGHT_MODEL:-$light_model}
light_effort=${SOP_WORKER_LIGHT_EFFORT:-$light_effort}
[[ -n ${SOP_WORKER_LIGHT_MODEL:-} ]] && light_alias=$SOP_WORKER_LIGHT_MODEL
scout_model=${SOP_SCOUT_MODEL:-$scout_model}
scout_effort=${SOP_SCOUT_EFFORT:-$scout_effort}
[[ -n ${SOP_SCOUT_MODEL:-} ]] && scout_alias=$SOP_SCOUT_MODEL

printf '{"ecosystem":"%s","detected_by":"%s","lead":{"model":"%s","effort":"%s","dispatch_model":"%s"},"worker":{"model":"%s","effort":"%s","dispatch_model":"%s"},"worker_light":{"model":"%s","effort":"%s","dispatch_model":"%s"},"scout":{"model":"%s","effort":"%s","dispatch_model":"%s"},"session_split":"%s"}\n' \
  "$ecosystem" "$(json_escape "$detected_by")" \
  "$(json_escape "$lead_model")" "$(json_escape "$lead_effort")" "$(json_escape "$lead_alias")" \
  "$(json_escape "$worker_model")" "$(json_escape "$worker_effort")" "$(json_escape "$worker_alias")" \
  "$(json_escape "$light_model")" "$(json_escape "$light_effort")" "$(json_escape "$light_alias")" \
  "$(json_escape "$scout_model")" "$(json_escape "$scout_effort")" "$(json_escape "$scout_alias")" \
  "$session_split"
