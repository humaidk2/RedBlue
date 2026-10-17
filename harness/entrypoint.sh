#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Harness entrypoint. One image, several roles — compose picks the role:
#
#   investigate [--headless [prompt]]   Pi against the local model (sealed net)
#   decompile                           APK -> /workspace     (network: none)
#   mobsf-scan                          APK -> MobSF -> /workspace/mobsf
#   healthcheck                         JSON status on stdout
#   shell                               bash, for poking around
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROLE="${1:-investigate}"; shift || true
mkdir -p "$HOME"

# Pi's view of the model: always the gateway, never the host-side URL in
# llm.env (that one is for the host and the control panel).
GATEWAY_URL="http://llm-gateway:8080"
PROVIDER="${PI_PROVIDER:-ollama}"

write_pi_config() {
  : "${LLM_MODEL:?LLM_MODEL missing — is llm.env loaded?}"
  local ctx="${LLM_CONTEXT_WINDOW:-32768}"
  mkdir -p "$PI_CODING_AGENT_DIR" "$PI_CODING_AGENT_SESSION_DIR"

  # The only provider Pi knows about (Ollama and LM Studio both speak the
  # OpenAI chat-completions API under /v1). apiKey is a required placeholder
  # the local server ignores. There are no cloud credentials in the image.
  jq -n --arg p "$PROVIDER" --arg url "$GATEWAY_URL/v1" --arg model "$LLM_MODEL" --argjson ctx "$ctx" '{
    providers: {
      ($p): {
        baseUrl: $url,
        api: "openai-completions",
        apiKey: "local",
        models: [{
          id: $model,
          contextWindow: $ctx,
          maxTokens: 8192,
          compat: { supportsDeveloperRole: false, supportsReasoningEffort: false }
        }]
      }
    }
  }' > "$PI_CODING_AGENT_DIR/models.json"

  jq -n --arg p "$PROVIDER" --arg model "$LLM_MODEL" '{
    defaultProvider: $p,
    defaultModel: $model,
    enableInstallTelemetry: false,
    enableAnalytics: false,
    quietStartup: true
  }' > "$PI_CODING_AGENT_DIR/settings.json"
}

# Flags shared by interactive and headless runs:
#  - no AGENTS.md/CLAUDE.md discovery, extensions, skills, templates, MCP, or
#    project-local config: the decompiled APK is attacker-controlled content and
#    must not be able to inject instructions or code into the harness.
PI_FLAGS=(
  --provider "$PROVIDER" --model "${LLM_MODEL:-}"
  --offline
  --no-context-files --no-extensions --no-skills --no-prompt-templates --no-mcp
  --no-approve
  --append-system-prompt /opt/apkscope/investigate-prompt.md
)

case "$ROLE" in
  investigate)
    write_pi_config
    # The model's shell commands get the allowlist proxy; Pi does not.
    export BASH_ENV=/opt/apkscope/proxy-env.sh
    cd /workspace
    if [ "${1:-}" = "--headless" ]; then
      shift
      PROMPT="${*:-Investigate this APK end to end following your brief, then write /findings/report.md.}"
      pi "${PI_FLAGS[@]}" -p "$PROMPT" | tee "/findings/headless-$(date -u +%Y%m%dT%H%M%SZ).log"
    else
      exec pi "${PI_FLAGS[@]}" "$@"
    fi
    ;;
  decompile)   exec /opt/apkscope/decompile.sh "$@" ;;
  mobsf-scan)  exec /opt/apkscope/mobsf-scan.sh "$@" ;;
  healthcheck) exec /opt/apkscope/healthcheck.sh "$@" ;;
  shell)       exec bash "$@" ;;
  *) echo "unknown role: $ROLE" >&2; exit 2 ;;
esac
