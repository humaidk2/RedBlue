#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate.sh — the gate. Refuses (exit 1) if anything looks wrong.
#
# Usage: scripts/validate.sh [decompile|investigate]   (default: investigate)
#
# Static checks (before anything starts):
#   1. llm.env       local/LAN endpoint only, provider ollama|lmstudio, no
#                    keys, telemetry off
#   2. ai-proxy/     filter lines are anchored public hostnames; no host, no
#                    localhost, no private ranges, no raw IPs; default-deny on
#   3. tools.txt     known tool ids only
#   4. inputs        APK present and a zip; workspace decompiled from THIS APK
#   5. images        built from the current tools.txt (setup has run)
#   6. compose       the rendered config really is sealed: harness only on the
#                    internal network, APK + workspace read-only, findings the
#                    only writable bind, decompile has no network, nothing
#                    publishes ports, nobody uses host networking or privileged
#   7. LLM server    reachable and the model is available (this host, or the
#                    one private-LAN IP in llm.env)
# apkscope.sh then runs healthcheck.sh inside the sealed network and refuses to
# start Pi unless the live seal probe passes too.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGE="${1:-investigate}"
FAILS=0; WARNS=0
fail() { echo -e "  ${RED}✕ $*${RESET}"; FAILS=$((FAILS+1)); }
warn() { echo -e "  ${YELLOW}! $*${RESET}"; WARNS=$((WARNS+1)); }

load_config
echo -e "${BOLD}ApkScope validate (${STAGE})${RESET}"

# ── 1. llm.env ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}llm.env${RESET}"
ALLOWED_KEYS="LLM_ENDPOINT LLM_MODEL LLM_CONTEXT_WINDOW PI_PROVIDER PI_TELEMETRY_DISABLED"
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  key="${line%%=*}"
  [[ " $ALLOWED_KEYS " == *" $key "* ]] || fail "unexpected key '$key' (allowed: $ALLOWED_KEYS) — no API keys, no telemetry endpoints"
done < llm.env
# The model runs on THIS machine or on ONE box on your private LAN, named by
# IP literal (a hostname could be re-pointed by DNS). Nothing public.
LOCAL_RE='^http://(localhost|127\.0\.0\.1|host\.docker\.internal)(:[0-9]{1,5})?/?$'
LAN_RE='^http://(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})(:[0-9]{1,5})?/?$'
if [[ "$LLM_ENDPOINT" =~ $LOCAL_RE ]]; then
  ok "endpoint $LLM_ENDPOINT is on this machine (llm-gateway → host.docker.internal:$LLM_TARGET_PORT)"
elif [[ "$LLM_ENDPOINT" =~ $LAN_RE ]]; then
  ok "endpoint $LLM_ENDPOINT is a private-LAN machine (llm-gateway → $LLM_TARGET_HOST:$LLM_TARGET_PORT, nothing else)"
else
  fail "LLM_ENDPOINT '$LLM_ENDPOINT' must be http://localhost|127.0.0.1|host.docker.internal[:port] or a private LAN IP (10/8, 172.16/12, 192.168/16) — no public or DNS-named endpoints"
fi
[[ "$LLM_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] && ok "model $LLM_MODEL" || fail "LLM_MODEL '$LLM_MODEL' is empty or has odd characters"
case "$PI_PROVIDER" in
  ollama|lmstudio) ok "provider $PI_PROVIDER (local, OpenAI-compatible)" ;;
  *) fail "PI_PROVIDER must be 'ollama' or 'lmstudio' (no cloud providers)" ;;
esac
[ "$(env_get llm.env PI_TELEMETRY_DISABLED)" = 1 ] && ok "telemetry disabled" || fail "PI_TELEMETRY_DISABLED must be 1"
CTX="$(env_get llm.env LLM_CONTEXT_WINDOW)"
[ -z "$CTX" ] || [[ "$CTX" =~ ^[0-9]+$ ]] || fail "LLM_CONTEXT_WINDOW must be a number"

# ── 2. Egress allowlist ───────────────────────────────────────────────────────
echo -e "\n${BOLD}ai-proxy/filter${RESET}"
N=0
# Exactly the panel's form: (^|\.)host\.name$  — anchored, dots escaped. Kept
# in a variable: inline in [[ =~ ]] bash mangles the backslashes.
FILTER_RE='^\(\^\|\\\.\)(([a-z0-9-]+\\\.)+[a-z][a-z0-9-]*)\$$'
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  if [[ ! "$line" =~ $FILTER_RE ]]; then
    fail "'$line' is not an anchored host pattern like (^|\\.)example\\.com\$ — regenerate it from the panel"
    continue
  fi
  host="${BASH_REMATCH[1]//\\./.}"
  case "$host" in
    localhost|*.localhost|*.local|*.internal|*.lan|*.home|*.arpa|*docker*)
      fail "'$host' points back at this machine or the LAN — the only host-ward route is llm-gateway" ;;
    *) ok "allow $host"; N=$((N+1)) ;;
  esac
done < ai-proxy/filter
[ "$N" = 0 ] && ok "empty allowlist — fully air-gapped"
grep -qE '^FilterDefaultDeny[[:space:]]+Yes' ai-proxy/tinyproxy.conf || fail "tinyproxy.conf must keep FilterDefaultDeny Yes"
grep -qE '^[[:space:]]*Upstream' ai-proxy/tinyproxy.conf && fail "tinyproxy.conf must not chain to an Upstream proxy"
[ "$(grep -cE '^ConnectPort' ai-proxy/tinyproxy.conf)" = 1 ] && grep -qE '^ConnectPort[[:space:]]+443$' ai-proxy/tinyproxy.conf \
  || fail "tinyproxy.conf must allow CONNECT to 443 only"

# ── 3. tools.txt ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}tools.txt${RESET}"
KNOWN="default-jre unzip apktool jadx ripgrep trufflehog gitleaks hermes-dec mobsf"
SEL="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' tools.txt | grep -v '^$' || true)"
for t in $SEL; do [[ " $KNOWN " == *" $t "* ]] || fail "unknown tool '$t' (known: $KNOWN)"; done
tool_selected default-jre || fail "default-jre is required (apktool and jadx need Java)"
tool_selected jadx || tool_selected apktool || warn "neither jadx nor apktool selected — the model will only see raw files"
ok "selected: $(echo "$SEL" | tr '\n' ' ')"

# ── 4. Inputs ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}inputs${RESET}"
if [ -f "$APK_PATH" ] && [ "$(head -c 2 "$APK_PATH")" = PK ]; then
  APK_SHA="$(sha256 "$APK_PATH")"; ok "APK $APK_PATH (sha256 ${APK_SHA:0:12}…)"
else
  fail "no APK (zip) at $APK_PATH — set APK_PATH in apkscope.config.sh"; APK_SHA=""
fi
if [ "$STAGE" = investigate ]; then
  if [ ! -f "$WORKSPACE_DIR/manifest.json" ]; then
    fail "workspace not decompiled — run ./apkscope.sh decompile"
  elif [ -n "$APK_SHA" ] && [ "$(cat "$WORKSPACE_DIR/apk.sha256" 2>/dev/null)" != "$APK_SHA" ]; then
    fail "workspace was decompiled from a DIFFERENT APK — run ./apkscope.sh decompile"
  else
    ok "workspace matches this APK"
  fi
  if tool_selected mobsf && [ ! -s "$WORKSPACE_DIR/mobsf/report.json" ]; then
    warn "mobsf selected but no report yet — run ./apkscope.sh scan (continuing without it)"
  fi
fi

# ── 5. Images ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}images${RESET}"
command -v docker >/dev/null || die "docker not found"
IMG_SHA="$(docker image inspect -f '{{index .Config.Labels "apkscope.tools_sha"}}' apkscope-harness:latest 2>/dev/null || true)"
if [ -z "$IMG_SHA" ]; then
  fail "harness image not built — run ./apkscope.sh setup"
elif [ "$IMG_SHA" != "$TOOLS_SHA" ]; then
  fail "harness image was built from a different tools.txt — run ./apkscope.sh setup"
else
  ok "harness image matches tools.txt"
fi
for img in apkscope-egress-proxy:latest apkscope-llm-gateway:latest; do
  docker image inspect "$img" >/dev/null 2>&1 && ok "$img" || fail "$img not built — run ./apkscope.sh setup"
done
if tool_selected mobsf; then
  docker image inspect "$MOBSF_IMAGE" >/dev/null 2>&1 && ok "$MOBSF_IMAGE (pre-pulled)" || fail "$MOBSF_IMAGE not pulled — run ./apkscope.sh setup"
fi

# ── 6. Rendered compose config ────────────────────────────────────────────────
echo -e "\n${BOLD}compose (rendered)${RESET}"
if [ -n "$IMG_SHA" ]; then
  RENDERED="$(compose --profile stages --profile mobsf config --format json)" || die "docker compose config failed"
  # jq runs inside the harness image (no network) so the host needs only docker.
  RESULT="$(printf '%s' "$RENDERED" | docker run --rm -i --network none --entrypoint jq apkscope-harness:latest -r '
    def chk(c; m): if c then "OK " + m else "FAIL " + m end;
    def binds(s): [ (s.volumes // [])[] | select(.type == "bind") ];
    . as $c | .services as $s |
    chk(($s.harness.networks | keys) == ["sealed"]; "harness is attached only to the sealed network"),
    chk($c.networks.sealed.internal == true; "sealed network is internal (no gateway)"),
    chk($c.networks.scan.internal == true; "scan network is internal"),
    chk($s.decompile.network_mode == "none"; "decompile has no network"),
    chk(([binds($s.harness)[] | select(.target == "/input/app.apk" or .target == "/workspace") | .read_only] | length == 2 and all);
        "APK and workspace are read-only for the model"),
    chk(([binds($s.harness)[] | select(.read_only != true) | .target] == ["/findings"]); "/findings is the only writable mount"),
    chk(($s.harness.read_only == true); "harness root filesystem is read-only"),
    chk(($s.harness.user // "0" | test("^(0|root)(:|$)") | not); "harness runs non-root"),
    chk(($s["llm-gateway"].networks | keys | sort) == ["hostward","sealed"]; "llm-gateway bridges only sealed ↔ hostward"),
    chk(($s["egress-proxy"].networks | keys | sort) == ["sealed","upstream"]; "egress-proxy bridges only sealed ↔ upstream"),
    chk((($s.mobsf.networks | keys) == ["scan"]) and (($s["mobsf-scan"].networks | keys) == ["scan"]); "MobSF lives only on the scan network"),
    chk(([$s[] | select(.ports)] | length) == 0; "no service publishes ports to the host"),
    chk(([$s[] | select(.network_mode == "host" or .privileged == true)] | length) == 0; "no host networking, nothing privileged"),
    chk(([$s.harness.environment // {} | to_entries[] | select(.key | test("API_KEY|TOKEN|SECRET|PROXY"; "i"))] | length) == 0;
        "harness env has no keys/tokens and no proxy vars for Pi itself")
  ')"
  while IFS= read -r r; do
    case "$r" in OK\ *) ok "${r#OK }" ;; FAIL\ *) fail "${r#FAIL }" ;; esac
  done <<< "$RESULT"
else
  warn "skipped (needs the harness image)"
fi

# ── 7. Host LLM ───────────────────────────────────────────────────────────────
if [ "$STAGE" = investigate ]; then
  echo -e "\n${BOLD}LLM server${RESET}"
  if MODELS="$(curl -sf --max-time 5 "$LLM_HOST_URL/v1/models")"; then
    ok "$PI_PROVIDER answers at $LLM_HOST_URL"
    model_listed "$MODELS" "$LLM_MODEL" && ok "model $LLM_MODEL is available" \
      || fail "model $LLM_MODEL not listed by $LLM_HOST_URL/v1/models — pull/download it first"
    # LM Studio reports the context the model is actually loaded with. If it's
    # smaller than what Pi is told, requests overflow mid-investigation.
    if [ "$PI_PROVIDER" = lmstudio ]; then
      LOADED="$(curl -sf --max-time 5 "$LLM_HOST_URL/api/v0/models/$LLM_MODEL" | tr -d ' \n' | sed -nE 's/.*"loaded_context_length":([0-9]+).*/\1/p')"
      WANT_CTX="${CTX:-32768}"
      if [ -z "$LOADED" ]; then
        warn "LM Studio has $LLM_MODEL not loaded yet (it will JIT-load) — make sure its context length is ≥ $WANT_CTX"
      elif [ "$LOADED" -lt "$WANT_CTX" ]; then
        fail "LM Studio loaded $LLM_MODEL with a $LOADED-token context, but LLM_CONTEXT_WINDOW=$WANT_CTX — reload it in LM Studio with Context Length ≥ $WANT_CTX (or: lms load $LLM_MODEL --context-length $WANT_CTX)"
      else
        ok "LM Studio context $LOADED ≥ $WANT_CTX"
      fi
    fi
  else
    fail "nothing answering at $LLM_HOST_URL/v1/models — start the LLM server (see README: it must listen beyond 127.0.0.1)"
  fi
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo -e "${RED}${BOLD}REFUSING: $FAILS problem(s), $WARNS warning(s).${RESET}"; exit 1
fi
echo -e "${GREEN}${BOLD}Validated${RESET} ($WARNS warning(s))."
