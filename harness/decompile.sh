#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# decompile.sh — the pre-stage. Runs with network_mode: none.
#
#   /input/app.apk (ro)  ─►  /workspace/
#       raw/          unzip of the APK (it is a zip)
#       apktool/      decoded AndroidManifest.xml, smali, res/
#       jadx/         readable Java (sources/) + resources/
#       rn/           React Native: index.android.bundle (+ decompiled.js if Hermes)
#       apk.sha256    ties this workspace to the exact APK it came from
#       manifest.json what was produced, for validate.sh and the model
#
# A tool that isn't installed (not in tools.txt) is skipped, not fatal.
# A tool that fails is recorded in manifest.json and the run continues — jadx
# routinely exits non-zero on a few classes while producing usable output.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APK=/input/app.apk
OUT=/workspace

[ -f "$APK" ] || { echo "no APK at $APK" >&2; exit 1; }
[ "$(head -c 2 "$APK")" = "PK" ] || { echo "$APK is not a zip/APK" >&2; exit 1; }

# Start clean: stale output from a previous APK must never mix with this one.
find "$OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

declare -A RESULT
run() { # run <name> <cmd...>
  local name="$1"; shift
  echo "── $name"
  if "$@"; then RESULT[$name]=ok; else RESULT[$name]="exit $?"; echo "   $name finished with errors (kept partial output)"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

if have unzip; then
  run raw unzip -q -o "$APK" -d "$OUT/raw"
fi

if have apktool; then
  # Framework files live under $HOME (tmpfs); apktool ships the stock one.
  run apktool apktool d -f -o "$OUT/apktool" "$APK"
fi

if have jadx; then
  JAVA_OPTS="-Xmx${JAVA_HEAP:-4g}" run jadx jadx --show-bad-code --deobf -d "$OUT/jadx" "$APK"
fi

# ── React Native ──────────────────────────────────────────────────────────────
BUNDLE=""
for c in "$OUT/raw/assets/index.android.bundle" "$OUT/apktool/assets/index.android.bundle" \
         "$OUT/jadx/resources/assets/index.android.bundle"; do
  [ -f "$c" ] && { BUNDLE="$c"; break; }
done
RN_KIND=none
if [ -n "$BUNDLE" ]; then
  mkdir -p "$OUT/rn"
  cp "$BUNDLE" "$OUT/rn/index.android.bundle"
  # Hermes bytecode magic: 0x1F1903C103BC1FC6, little-endian on disk.
  if [ "$(od -An -tx1 -N8 "$BUNDLE" | tr -d ' \n')" = "c61fbc03c103191f" ]; then
    RN_KIND=hermes
    if have hbc-decompiler; then
      run hermes-dec hbc-decompiler "$OUT/rn/index.android.bundle" "$OUT/rn/decompiled.js"
    else
      echo "── Hermes bundle found but hermes-dec is not selected in tools.txt"
    fi
  else
    RN_KIND=plain-js   # already readable JavaScript
  fi
fi

sha256sum "$APK" | awk '{print $1}' > "$OUT/apk.sha256"

{
  printf '{\n  "apk_sha256": "%s",\n  "generated_at": "%s",\n  "react_native": "%s",\n  "stages": {' \
    "$(cat "$OUT/apk.sha256")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RN_KIND"
  sep=""
  for k in "${!RESULT[@]}"; do printf '%s\n    "%s": "%s"' "$sep" "$k" "${RESULT[$k]}"; sep=","; done
  printf '\n  }\n}\n'
} > "$OUT/manifest.json"

echo
cat "$OUT/manifest.json"
