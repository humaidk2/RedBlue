#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mobsf-scan.sh — drive MobSF's REST API to scan the APK and save its JSON
# report to /workspace/mobsf/report.json for the model to read.
#
# Runs on the `scan` network, which is internal: MobSF and this client can
# talk to each other and to nothing else. The model never talks to MobSF; it
# only reads the saved report (read-only) during the investigation.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APK=/input/app.apk
OUT=/workspace/mobsf
API="http://mobsf:8000/api/v1"
KEY="${MOBSF_API_KEY:?MOBSF_API_KEY not set}"

mkdir -p "$OUT"

echo "Waiting for MobSF to come up (first start runs migrations)..."
for i in $(seq 1 90); do
  # Any HTTP answer means the server is up; the API rejects GETs, that's fine.
  if curl -s -o /dev/null --max-time 3 "http://mobsf:8000/"; then break; fi
  [ "$i" = 90 ] && { echo "MobSF did not start within 3 minutes" >&2; exit 1; }
  sleep 2
done

echo "Uploading $(basename "$APK")..."
HASH="$(curl -sf --max-time 600 -H "Authorization: $KEY" -F "file=@$APK" "$API/upload" | jq -r .hash)"
[ -n "$HASH" ] && [ "$HASH" != null ] || { echo "upload failed" >&2; exit 1; }

echo "Scanning ($HASH) — large APKs take several minutes..."
curl -sf --max-time 3600 -H "Authorization: $KEY" --data "hash=$HASH" "$API/scan" > /dev/null

curl -sf --max-time 600 -H "Authorization: $KEY" --data "hash=$HASH" "$API/report_json" > "$OUT/report.json"
curl -sf --max-time 600 -H "Authorization: $KEY" --data "hash=$HASH" "$API/scorecard" > "$OUT/scorecard.json" || true

echo "Saved $OUT/report.json ($(du -h "$OUT/report.json" | cut -f1))"
