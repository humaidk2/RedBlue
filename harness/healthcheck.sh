#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# healthcheck.sh — runs INSIDE the harness container, on the same `sealed`
# network the investigation uses, and prints status JSON on stdout.
# apkscope.sh saves it as status.json next to the control panel.
#
# Besides "is it up", it proves the seal from the model's own vantage point:
#   - no direct route to the internet, bypassing the proxy
#   - no direct route to the host
#   - the proxy refuses a host that isn't allowlisted, and refuses the host
#   - the only thing that answers is llm-gateway, with the configured model
# `sealed` is true only if every one of those holds. apkscope.sh refuses to
# start an investigation otherwise.
# ─────────────────────────────────────────────────────────────────────────────
set -u

GW="http://llm-gateway:8080"
PROXY="http://egress-proxy:8888"
MODEL="${LLM_MODEL:-}"
TARGET="${LLM_TARGET_HOST:-host.docker.internal}:${LLM_TARGET_PORT:-11434}"

b() { "$@" && echo true || echo false; }               # command -> true/false
fails() { "$@" && echo false || echo true; }           # true if the command FAILS
has() { command -v "$1" >/dev/null 2>&1 && echo true || echo false; }

# HTTP status code of a request through the proxy ("000" = no answer at all).
via_proxy() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -x "$PROXY" "$1" 2>/dev/null; }

# ── LLM ──────────────────────────────────────────────────────────────────────
# OpenAI-compatible model list — served by both Ollama and LM Studio.
MODELS="$(curl -sf --noproxy '*' --max-time 6 "$GW/v1/models" 2>/dev/null)"
if [ -n "$MODELS" ]; then LLM=true; else LLM=false; fi
MODEL_PRESENT=false
if [ -n "$MODELS" ] && [ -n "$MODEL" ]; then
  # Ollama treats a bare name as ":latest".
  want="$MODEL"
  [ "${PI_PROVIDER:-}" = ollama ] && case "$want" in *:*) ;; *) want="$want:latest" ;; esac
  echo "$MODELS" | jq -e --arg m "$want" '.data[]? | select(.id == $m)' >/dev/null 2>&1 && MODEL_PRESENT=true
fi

# ── Proxy ────────────────────────────────────────────────────────────────────
# A host that can never be allowlisted: tinyproxy must answer 403 for it.
DENY_CODE="$(via_proxy http://apkscope-seal-probe.invalid/)"
PROXY_UP=$([ "$DENY_CODE" != "000" ] && echo true || echo false)
PROXY_DENIES=$([ "$DENY_CODE" = "403" ] && echo true || echo false)
HOST_CODE="$(via_proxy http://host.docker.internal:11434/)"
PROXY_DENIES_HOST=$([ "$HOST_CODE" = "403" ] && echo true || echo false)
# The LLM box itself is reachable ONLY via llm-gateway, never via the proxy.
LLMBOX_CODE="$(via_proxy "http://$TARGET/v1/models")"
PROXY_DENIES_LLM=$([ "$LLMBOX_CODE" = "403" ] && echo true || echo false)

# ── Direct routes (bypassing the proxy) must not exist ──────────────────────
NO_DIRECT_NET=$(fails curl -s -o /dev/null --noproxy '*' --max-time 4 https://1.1.1.1/)
NO_DIRECT_DNS=$(fails curl -s -o /dev/null --noproxy '*' --max-time 4 http://example.com/)
NO_DIRECT_HOST=$(fails curl -s -o /dev/null --noproxy '*' --max-time 4 http://host.docker.internal:11434/)
NO_DIRECT_LLM=$(fails curl -s -o /dev/null --noproxy '*' --max-time 4 "http://$TARGET/v1/models")
# A typical LAN router — proves there's no LAN reach beyond the one route.
NO_DIRECT_LAN=$(fails curl -s -o /dev/null --noproxy '*' --max-time 4 http://192.168.1.1/)

SEALED=false
if [ "$PROXY_DENIES" = true ] && [ "$PROXY_DENIES_HOST" = true ] && [ "$PROXY_DENIES_LLM" = true ] \
   && [ "$NO_DIRECT_NET" = true ] && [ "$NO_DIRECT_DNS" = true ] && [ "$NO_DIRECT_HOST" = true ] \
   && [ "$NO_DIRECT_LLM" = true ] && [ "$NO_DIRECT_LAN" = true ]; then
  SEALED=true
fi

# ── Workspace / mounts ───────────────────────────────────────────────────────
DECOMPILED=$(b test -f /workspace/manifest.json)
WS_RO=$(fails touch /workspace/.apkscope-write-probe 2>/dev/null)
APK_RO=$(fails touch /input/app.apk 2>/dev/null)
FINDINGS_RW=$(b sh -c 'touch /findings/.probe && rm -f /findings/.probe' 2>/dev/null)
MOBSF_REPORT=$(b test -s /workspace/mobsf/report.json)

# ── Tools (keys match the control panel's `check` names) ─────────────────────
TOOLS_JSON="$(
  sed -e 's/#.*//' -e 's/[[:space:]]//g' /opt/apkscope/tools.txt | grep -v '^$' | while read -r id; do
    case "$id" in
      default-jre) echo "java $(has java)" ;;
      unzip)       echo "unzip $(has unzip)" ;;
      apktool)     echo "apktool $(has apktool)" ;;
      jadx)        echo "jadx $(has jadx)" ;;
      ripgrep)     echo "rg $(has rg)" ;;
      trufflehog)  echo "trufflehog $(has trufflehog)" ;;
      gitleaks)    echo "gitleaks $(has gitleaks)" ;;
      hermes-dec)  echo "hbc-decompiler $(has hbc-decompiler)" ;;
      mobsf)       echo "mobsf $MOBSF_REPORT" ;;
      *)           echo "$id false" ;;
    esac
  done | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] == "true")}] | add // {}'
)"

jq -n \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg model "$MODEL" \
  --argjson llm "$LLM" --argjson model_present "$MODEL_PRESENT" \
  --argjson proxy "$PROXY_UP" --argjson sealed "$SEALED" \
  --argjson proxy_denies "$PROXY_DENIES" --argjson proxy_denies_host "$PROXY_DENIES_HOST" \
  --argjson no_direct_net "$NO_DIRECT_NET" --argjson no_direct_dns "$NO_DIRECT_DNS" \
  --argjson no_direct_host "$NO_DIRECT_HOST" --argjson no_direct_llm "$NO_DIRECT_LLM" \
  --argjson no_direct_lan "$NO_DIRECT_LAN" --argjson proxy_denies_llm "$PROXY_DENIES_LLM" \
  --argjson decompiled "$DECOMPILED" --argjson ws_ro "$WS_RO" --argjson apk_ro "$APK_RO" \
  --argjson findings_rw "$FINDINGS_RW" --argjson mobsf "$MOBSF_REPORT" \
  --argjson tools "$TOOLS_JSON" '{
    generated_at: $at,
    llm: $llm, model: $model, model_present: $model_present,
    proxy: $proxy, sealed: $sealed,
    seal_checks: {
      proxy_denies_unlisted: $proxy_denies, proxy_denies_host: $proxy_denies_host,
      proxy_denies_llm_box: $proxy_denies_llm,
      no_direct_internet: $no_direct_net, no_direct_dns: $no_direct_dns,
      no_direct_host: $no_direct_host, no_direct_llm_box: $no_direct_llm,
      no_direct_lan: $no_direct_lan
    },
    mounts: { workspace_read_only: $ws_ro, apk_read_only: $apk_ro, findings_writable: $findings_rw },
    decompiled: $decompiled, mobsf_report: $mobsf,
    tools: $tools
  }'
