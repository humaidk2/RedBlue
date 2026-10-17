# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers for apkscope.sh and validate.sh: load apkscope.config.sh +
# llm.env, resolve paths, export what docker-compose.yml expects.
# ─────────────────────────────────────────────────────────────────────────────

BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck disable=SC2034  # colours and LLM_* are used by the scripts that source this

die()  { echo -e "${RED}✕ $*${RESET}" >&2; exit 1; }
info() { echo -e "${CYAN}›${RESET} $*"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$REPO_ROOT/${1#./}" ;; esac; }

# Read KEY=VALUE from an env-style file without executing it.
env_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

load_config() {
  [ -f apkscope.config.sh ] || die "apkscope.config.sh missing"
  # shellcheck source=../apkscope.config.sh
  source apkscope.config.sh

  APK_PATH="$(abspath "$APK_PATH")"
  WORKSPACE_DIR="$(abspath "$WORKSPACE_DIR")"
  FINDINGS_DIR="$(abspath "$FINDINGS_DIR")"

  # The decompile stage wipes WORKSPACE_DIR; never let that be something big.
  for d in "$WORKSPACE_DIR" "$FINDINGS_DIR"; do
    case "$d" in /|"$HOME"|"$REPO_ROOT"|"$REPO_ROOT/") die "refusing to use $d as a data dir — point it at a dedicated folder" ;; esac
  done

  [ -f llm.env ] || die "llm.env missing — generate it from the control panel (./apkscope.sh panel)"
  LLM_ENDPOINT="$(env_get llm.env LLM_ENDPOINT)"
  LLM_MODEL="$(env_get llm.env LLM_MODEL)"
  PI_PROVIDER="$(env_get llm.env PI_PROVIDER)"
  # The one destination llm-gateway forwards to, parsed from the endpoint.
  # This machine (localhost/127.0.0.1/host.docker.internal) → host.docker.internal;
  # a LAN box (private IPv4 literal, validated) → that IP.
  local ep_host
  ep_host="$(echo "$LLM_ENDPOINT" | sed -nE 's#^https?://([^/:]+).*#\1#p')"
  LLM_TARGET_PORT="$(echo "$LLM_ENDPOINT" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')"
  LLM_TARGET_PORT="${LLM_TARGET_PORT:-11434}"
  case "$ep_host" in
    localhost|127.0.0.1|host.docker.internal) LLM_TARGET_HOST=host.docker.internal; LLM_HOST_URL="http://127.0.0.1:$LLM_TARGET_PORT" ;;
    *) LLM_TARGET_HOST="$ep_host"; LLM_HOST_URL="http://$ep_host:$LLM_TARGET_PORT" ;;
  esac

  TOOLS_SHA="$(sha256 tools.txt)"
  # Per-run random key; MobSF only lives for one scan on an internal network.
  MOBSF_API_KEY="${MOBSF_API_KEY:-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')}"

  HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
  # Never run the containers as root, even if the host user is root.
  [ "$HOST_UID" = 0 ] && { HOST_UID=10001; HOST_GID=10001; }

  export APK_PATH WORKSPACE_DIR FINDINGS_DIR HARNESS_MEMORY DECOMPILE_MEMORY DECOMPILE_JAVA_HEAP \
         MOBSF_MEMORY MOBSF_IMAGE HARNESS_PIDS PI_VERSION APKSCOPE_PLATFORM LLM_TARGET_HOST LLM_TARGET_PORT \
         TOOLS_SHA MOBSF_API_KEY HOST_UID HOST_GID
  export COMPOSE_PROJECT_NAME=apkscope
}

# Is the model listed by the server's OpenAI-compatible /v1/models? (Ollama and
# LM Studio both serve it.) Ollama treats a bare name as ":latest".
model_listed() { # model_listed <models-json> <model>
  local want="$2"
  [ "$PI_PROVIDER" = ollama ] && [[ "$want" != *:* ]] && want="$want:latest"
  printf '%s' "$1" | tr -d ' \n\t' | grep -qF "\"id\":\"$want\""
}

tool_selected() { sed -e 's/#.*//' -e 's/[[:space:]]//g' tools.txt | grep -qx "$1"; }

compose() { docker compose -f "$REPO_ROOT/docker-compose.yml" "$@"; }
