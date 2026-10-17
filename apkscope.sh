#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# apkscope.sh — the single driver. Config: apkscope.config.sh (+ the panel's
# ai-proxy/filter, tools.txt, llm.env). You never edit the scripts.
#
#   ONLINE (once, or after changing tools.txt / versions):
#     ./apkscope.sh setup          build images, pre-pull MobSF, pull the model
#
#   SEALED (no internet needed from here on):
#     ./apkscope.sh decompile      APK -> workspace/   (network: none)
#     ./apkscope.sh scan           MobSF report -> workspace/mobsf/ (if selected)
#     ./apkscope.sh investigate    validate → seal probe → Pi (interactive)
#     ./apkscope.sh headless [prompt]   same, one-shot; report lands in findings/
#     ./apkscope.sh run            decompile + scan + headless, end to end
#
#   UTILITIES:
#     ./apkscope.sh validate       run the gate only
#     ./apkscope.sh health         write status.json (starts proxy + gateway)
#     ./apkscope.sh panel          serve the control panel on 127.0.0.1
#     ./apkscope.sh shell          bash in the sealed harness
#     ./apkscope.sh down           stop everything
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; shift || true
load_config

# ── stages ────────────────────────────────────────────────────────────────────
cmd_setup() {
  info "Online setup phase — this is the only step that needs the internet."
  compose build --pull harness egress-proxy llm-gateway
  if tool_selected mobsf; then
    info "Pulling $MOBSF_IMAGE"
    docker pull ${APKSCOPE_PLATFORM:+--platform "$APKSCOPE_PLATFORM"} "$MOBSF_IMAGE"
  fi
  local models
  models="$(curl -sf --max-time 5 "$LLM_HOST_URL/v1/models" || true)"
  if [ -n "$models" ] && model_listed "$models" "$LLM_MODEL"; then
    ok "model $LLM_MODEL available at $LLM_HOST_URL"
  elif [ "$PI_PROVIDER" = ollama ] && [ "$LLM_TARGET_HOST" = host.docker.internal ] && command -v ollama >/dev/null; then
    info "Pulling $LLM_MODEL into the host's Ollama"
    ollama pull "$LLM_MODEL"
  else
    echo -e "${YELLOW}! $LLM_MODEL not available at $LLM_HOST_URL — start the server and download/load the model there${RESET}"
  fi
  mkdir -p "$(dirname "$APK_PATH")" "$WORKSPACE_DIR" "$FINDINGS_DIR"
  ok "Setup done. Everything after this runs sealed. Put the APK at $APK_PATH"
}

cmd_decompile() {
  scripts/validate.sh decompile
  mkdir -p "$WORKSPACE_DIR"
  info "Decompiling (no network)…"
  compose run --rm --no-deps decompile
}

cmd_scan() {
  tool_selected mobsf || { info "mobsf not selected in tools.txt — skipping scan"; return 0; }
  [ -f "$WORKSPACE_DIR/manifest.json" ] || die "decompile first (the decompile stage resets workspace/)"
  info "MobSF scan on the internal scan network…"
  compose --profile mobsf up -d mobsf
  local rc=0
  compose --profile mobsf run --rm --no-deps mobsf-scan || rc=$?
  # MobSF only lives for the one scan.
  compose --profile mobsf rm -sf mobsf >/dev/null 2>&1 || true
  [ "$rc" = 0 ] || die "MobSF scan failed (exit $rc)"
}

# Start proxy + gateway, run the seal probe inside the sealed network, save
# status.json. Returns non-zero unless the LLM answers and the seal holds.
cmd_health() {
  mkdir -p "$FINDINGS_DIR"
  compose up -d egress-proxy llm-gateway >/dev/null
  local json
  json="$(compose run --rm --no-deps -T harness healthcheck)" || true
  [ -n "$json" ] || die "healthcheck produced no output"
  printf '%s\n' "$json" > status.json
  echo "$json" | docker run --rm -i --network none --entrypoint jq apkscope-harness:latest -r '
    def m(v): if v == true then "✓" elif v == false then "✕" else "○" end;
    "  \(m(.llm)) LLM reachable via llm-gateway     \(m(.model_present)) model \(.model)",
    "  \(m(.proxy)) egress proxy up                  \(m(.sealed)) SEALED",
    (.seal_checks | to_entries[] | "      \(m(.value)) \(.key)"),
    (.mounts | to_entries[] | "      \(m(.value)) \(.key)"),
    "  tools: " + ([.tools | to_entries[] | "\(m(.value)) \(.key)"] | join("  "))'
  info "wrote status.json"
  echo "$json" | grep -q '"sealed": true' || die "seal probe FAILED — refusing (see status.json)"
  echo "$json" | grep -q '"llm": true' || die "LLM not reachable through llm-gateway ($LLM_TARGET_HOST:$LLM_TARGET_PORT) — is the server listening beyond 127.0.0.1? (README)"
  echo "$json" | grep -q '"model_present": true' || die "model $LLM_MODEL not listed by the LLM server"
}

preflight() {
  scripts/validate.sh investigate
  mkdir -p "$FINDINGS_DIR"
  info "Live seal probe from inside the sealed network…"
  cmd_health
}

cmd_investigate() { preflight; compose run --rm --no-deps harness investigate "$@"; }
cmd_headless()    { preflight; compose run --rm --no-deps -T harness investigate --headless "$@"; ok "report: $FINDINGS_DIR/report.md"; }
cmd_run()         { cmd_decompile; cmd_scan; cmd_headless "$@"; }
cmd_shell()       { preflight; compose run --rm --no-deps --entrypoint bash harness; }
cmd_down()        { compose --profile stages --profile mobsf down --remove-orphans; }

cmd_panel() {
  command -v python3 >/dev/null || die "python3 needed to serve the panel (or open apkscope-control-panel.html directly and use Download)"
  python3 scripts/panel-server.py "$PANEL_PORT"
}

case "$CMD" in
  setup) cmd_setup ;;
  decompile) cmd_decompile ;;
  scan) cmd_scan ;;
  investigate) cmd_investigate "$@" ;;
  headless) cmd_headless "$@" ;;
  run) cmd_run "$@" ;;
  validate) scripts/validate.sh "${1:-investigate}" ;;
  health) cmd_health ;;
  panel) cmd_panel ;;
  shell) cmd_shell ;;
  down) cmd_down ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $CMD" >&2; usage; exit 1 ;;
esac
