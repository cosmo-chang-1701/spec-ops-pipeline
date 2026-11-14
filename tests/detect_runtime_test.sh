#!/usr/bin/env bash
# Tests for detect_runtime.sh.  Run: bash tests/detect_runtime_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D=$SCRIPTS/detect_runtime.sh
# A clean env so the caller's agent markers and API keys do not leak into detection.
run() { env -i PATH="$PATH" HOME="$WORK" "$@" bash "$D" --agent "$AGENT"; }

section "claude defaults"
AGENT=claude; out=$(run)
check_eq "lead model" "$(json_get '["lead"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "lead effort" "$(json_get '["lead"]["effort"]' <<<"$out")" high
check_eq "phase 2 lead model" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "phase 2 lead effort" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" medium
check_eq "lead dispatch alias" "$(json_get '["lead"]["dispatch_model"]' <<<"$out")" opus
check_eq "phase 2 lead dispatch alias" "$(json_get '["lead_phase2"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "worker model" "$(json_get '["worker"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "worker effort" "$(json_get '["worker"]["effort"]' <<<"$out")" medium
check_eq "worker dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "light worker model" "$(json_get '["worker_light"]["model"]' <<<"$out")" claude-haiku-5-5
check_eq "light worker effort" "$(json_get '["worker_light"]["effort"]' <<<"$out")" medium
check_eq "light worker dispatch alias" "$(json_get '["worker_light"]["dispatch_model"]' <<<"$out")" haiku
check_eq "scout model" "$(json_get '["scout"]["model"]' <<<"$out")" claude-haiku-5-5
check_eq "scout effort" "$(json_get '["scout"]["effort"]' <<<"$out")" medium
check_eq "scout dispatch alias" "$(json_get '["scout"]["dispatch_model"]' <<<"$out")" haiku

SETTINGS=$WORK/.gemini/antigravity-cli/settings.json
mkdir -p "${SETTINGS%/*}"
# gemini_case <label> <settings content or ""> <profile> <source> <lead model> <worker model> <worker effort>
gemini_case() {
  rm -f "$SETTINGS"
  [[ -z $2 ]] || printf '%s\n' "$2" >"$SETTINGS"
  AGENT=gemini; out=$(run)
  local r
  check_eq "$1: detected_by" "$(json_get '["detected_by"]' <<<"$out")" "flag:--agent;model:$3($4)"
  check_eq "$1: lead" "$(json_get '["lead"]["model"]' <<<"$out")/$(json_get '["lead"]["effort"]' <<<"$out")/$(json_get '["lead"]["dispatch_model"]' <<<"$out")" "$5/high/$5"
  for r in lead_phase2 worker worker_light scout; do
    check_eq "$1: $r" "$(json_get "[\"$r\"][\"model\"]" <<<"$out")/$(json_get "[\"$r\"][\"effort\"]" <<<"$out")/$(json_get "[\"$r\"][\"dispatch_model\"]" <<<"$out")" "$6/$7/$6"
  done
}
section "gemini profiles"
gemini_case "no settings file" "" gemini-4 default gemini-4-argon-high gemini-4-hydrogen-high high
gemini_case "gemini 4 argon display name" '{
  "model": "Gemini 4 Argon (Medium)"
}' gemini-4 settings gemini-4-argon-high gemini-4-hydrogen-high high
gemini_case "gemini 4 argon id" '{
  "model": "gemini-4-argon-high"
}' gemini-4 settings gemini-4-argon-high gemini-4-hydrogen-high high
gemini_case "gemini 4 hydrogen display name" '{
  "model": "Gemini 4 Hydrogen (Medium)"
}' gemini-4-hydrogen settings gemini-4-hydrogen-high gemini-4-hydrogen-high high
gemini_case "gemini 4 hydrogen id" '{
  "model": "gemini-4-hydrogen-high"
}' gemini-4-hydrogen settings gemini-4-hydrogen-high gemini-4-hydrogen-high high
gemini_case "claude display name" '{
  "model": "Claude Opus 5.5 (High)"
}' claude settings claude-opus-5-5-high claude-sonnet-5-5-medium medium
gemini_case "claude sonnet display name" '{
  "model": "Claude Sonnet 5.5 (Medium)"
}' claude settings claude-opus-5-5-high claude-sonnet-5-5-medium medium
gemini_case "claude id" '{
  "model": "claude-sonnet-5-5-medium"
}' claude settings claude-opus-5-5-high claude-sonnet-5-5-medium medium
gemini_case "flash display name" '{
  "model": "Gemini 3.8 Flash (Low)"
}' gemini-3.8-flash settings gemini-3.8-flash-high gemini-3.8-flash-medium medium
gemini_case "flash id" '{
  "model": "gemini-3.8-flash-high"
}' gemini-3.8-flash settings gemini-3.8-flash-high gemini-3.8-flash-medium medium
gemini_case "unrecognised model" '{
  "model": "GPT-OSS 120B (Medium)"
}' gemini-4 default gemini-4-argon-high gemini-4-hydrogen-high high
gemini_case "top-level model wins over a later nested one" '{
  "model": "Gemini 3.8 Flash (High)",
  "permissions": {
    "model": "Gemini 4 Argon (High)"
  }
}' gemini-3.8-flash settings gemini-3.8-flash-high gemini-3.8-flash-medium medium
gemini_case "no model key" '{
  "colorScheme": "dark"
}' gemini-4 default gemini-4-argon-high gemini-4-hydrogen-high high
printf '{\n  "model": "Gemini 3.8 Flash (High)"\n}\n' >"$SETTINGS"
out=$(run SOP_WORKER_MODEL=x)
check_eq "SOP_WORKER_MODEL beats the profile" "$(json_get '["worker"]["model"]' <<<"$out")" x
check_eq "profile still applies to the lead" "$(json_get '["lead"]["model"]' <<<"$out")" gemini-3.8-flash-high
rm -f "$SETTINGS"
last=$(env -i PATH="$PATH" HOME="$WORK" bash "$D" --help | tail -n 1)
check_eq "--help ends at the last header line" "${last:0:1}" "#"
check_eq "--help does not print code" "$(env -i PATH="$PATH" HOME="$WORK" bash "$D" --help | grep -c '^set -euo')" 0

section "codex defaults"
AGENT=codex; out=$(run)
check_eq "codex lead" "$(json_get '["lead"]["model"]' <<<"$out")/$(json_get '["lead"]["effort"]' <<<"$out")/$(json_get '["lead"]["dispatch_model"]' <<<"$out")" gpt-6-astra/high/gpt-6-astra
check_eq "codex lead_phase2" "$(json_get '["lead_phase2"]["model"]' <<<"$out")/$(json_get '["lead_phase2"]["effort"]' <<<"$out")/$(json_get '["lead_phase2"]["dispatch_model"]' <<<"$out")" gpt-6.1-sol/medium/gpt-6.1-sol
check_eq "codex worker" "$(json_get '["worker"]["model"]' <<<"$out")/$(json_get '["worker"]["effort"]' <<<"$out")/$(json_get '["worker"]["dispatch_model"]' <<<"$out")" gpt-6.1-sol/medium/gpt-6.1-sol
check_eq "codex worker_light" "$(json_get '["worker_light"]["model"]' <<<"$out")/$(json_get '["worker_light"]["effort"]' <<<"$out")/$(json_get '["worker_light"]["dispatch_model"]' <<<"$out")" gpt-6-luna/medium/gpt-6-luna
check_eq "codex scout" "$(json_get '["scout"]["model"]' <<<"$out")/$(json_get '["scout"]["effort"]' <<<"$out")/$(json_get '["scout"]["dispatch_model"]' <<<"$out")" gpt-6-luna/medium/gpt-6-luna


section "overrides"
AGENT=claude; out=$(run SOP_LEAD2_MODEL=claude-opus-5-5 SOP_LEAD2_EFFORT=medium SOP_LEAD_EFFORT=max SOP_WORKER_MODEL=haiku)
check_eq "SOP_LEAD2_MODEL" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "SOP_LEAD2_EFFORT" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" medium
check_eq "SOP_LEAD2_MODEL sets the dispatch alias" "$(json_get '["lead_phase2"]["dispatch_model"]' <<<"$out")" claude-opus-5-5
check_eq "SOP_LEAD_MODEL sets the dispatch alias" "$(json_get '["lead"]["dispatch_model"]' <<<"$(run SOP_LEAD_MODEL=sonnet)")" sonnet
check_eq "SOP_LEAD_EFFORT leaves phase 2 alone" "$(json_get '["lead_phase2"]["effort"]' <<<"$(run SOP_LEAD_EFFORT=max)")" medium
check_eq "SOP_WORKER_MODEL sets the dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" haiku
out=$(run SOP_WORKER_LIGHT_MODEL=sonnet SOP_WORKER_LIGHT_EFFORT=low SOP_SCOUT_MODEL=sonnet SOP_SCOUT_EFFORT=medium)
check_eq "SOP_WORKER_LIGHT_MODEL sets the dispatch alias" "$(json_get '["worker_light"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "SOP_WORKER_LIGHT_EFFORT" "$(json_get '["worker_light"]["effort"]' <<<"$out")" low
check_eq "SOP_SCOUT_MODEL sets the dispatch alias" "$(json_get '["scout"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "SOP_SCOUT_EFFORT" "$(json_get '["scout"]["effort"]' <<<"$out")" medium
check_eq "session split defaults to auto" "$(json_get '["session_split"]' <<<"$out")" auto
check_eq "SOP_SESSION_SPLIT" "$(json_get '["session_split"]' <<<"$(run SOP_SESSION_SPLIT=never)")" never
run SOP_SESSION_SPLIT=bogus >/dev/null 2>&1; rc=$?
check_eq "invalid SOP_SESSION_SPLIT: exit 2" "$rc" 2

section "detection"
check_eq "--agent wins over runtime markers" \
  "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" --agent codex | json_get '["ecosystem"]')" codex
check_eq "Claude Code marker" "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" | json_get '["ecosystem"]')" claude
bash "$D" --agent other >/dev/null 2>&1; rc=$?
check_eq "invalid --agent: exit 2" "$rc" 2

finish
