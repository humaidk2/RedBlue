# ─────────────────────────────────────────────────────────────────────────────
# apkscope.config.sh — THE config file. Edit this, never the scripts.
#
# Policy (what the model may reach, which tools exist, which LLM it talks to)
# lives in the three files the control panel generates:
#     ai-proxy/filter   egress allowlist (default-deny; empty = fully air-gapped)
#     tools.txt         analysis tools baked into the harness image
#     llm.env           local LLM endpoint + model
# Open the panel with:  ./apkscope.sh panel
#
# Paths are relative to the repo root unless absolute.
# ─────────────────────────────────────────────────────────────────────────────

# The APK under investigation. Mounted READ-ONLY everywhere.
APK_PATH="./input/app.apk"

# Decompiled output (apktool / jadx / React Native bundle / MobSF report).
# Written ONLY by the decompile and scan stages (no network), then mounted
# READ-ONLY into the investigation.
WORKSPACE_DIR="./workspace"

# The one writable dir the model gets. Its report and Pi session logs land here.
FINDINGS_DIR="./findings"

# Resource caps.
HARNESS_MEMORY="4g"     # Pi + the shell tools the model runs
DECOMPILE_MEMORY="6g"   # jadx on a large APK is hungry
DECOMPILE_JAVA_HEAP="4g" # keep below DECOMPILE_MEMORY
MOBSF_MEMORY="4g"
HARNESS_PIDS="512"

# MobSF image (only used when "mobsf" is selected in tools.txt). Pin a tag you
# have tested; it is pulled during `./apkscope.sh setup` and never at run time.
MOBSF_IMAGE="opensecurity/mobile-security-framework-mobsf:latest"

# Pi version installed into the harness image (npm dist-tag or exact version).
PI_VERSION="latest"

# Build/run arch. Empty = host native (arm64 on Apple Silicon). e.g. linux/amd64
APKSCOPE_PLATFORM=""

# Local port for the control panel server (bound to 127.0.0.1 only).
PANEL_PORT="8765"
