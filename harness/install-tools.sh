#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-tools.sh — runs at IMAGE BUILD time (the online setup phase) and
# installs exactly the tools selected in tools.txt. Nothing is fetched at run
# time; the investigation container has no route to fetch anything anyway.
#
# Versions are pinned so a rebuild is reproducible. Bump them here.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TOOLS_FILE="${1:?usage: install-tools.sh tools.txt}"

JADX_VERSION="1.5.1"
TRUFFLEHOG_VERSION="3.88.0"
GITLEAKS_VERSION="8.21.2"
HERMES_DEC_SPEC="hermes-dec<0.1.8"   # 0.1.8 is days old; take the previous release

ARCH="$(dpkg --print-architecture)"   # amd64 | arm64

mapfile -t TOOLS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$TOOLS_FILE" | grep -v '^$')
want() { local t; for t in "${TOOLS[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

echo "Selected tools: ${TOOLS[*]}"

# ── apt ───────────────────────────────────────────────────────────────────────
APT=()
want default-jre && APT+=(default-jre-headless)
want unzip       && APT+=(unzip)
want apktool     && APT+=(apktool)
want ripgrep     && APT+=(ripgrep)
want hermes-dec  && APT+=(python3 python3-venv)
# jadx needs unzip to unpack its release zip even if the model doesn't get it.
want jadx        && APT+=(unzip)

if [ "${#APT[@]}" -gt 0 ]; then
  # Slim images drop man dirs; the OpenJDK postinst fails without this one.
  mkdir -p /usr/share/man/man1
  apt-get update
  apt-get install -y --no-install-recommends "${APT[@]}"
  rm -rf /var/lib/apt/lists/*
fi

# ── jadx (release zip) ───────────────────────────────────────────────────────
if want jadx; then
  curl -fsSL -o /tmp/jadx.zip \
    "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip"
  unzip -q /tmp/jadx.zip -d /opt/jadx
  ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx
  rm /tmp/jadx.zip
fi

# ── trufflehog (binary) ───────────────────────────────────────────────────────
if want trufflehog; then
  curl -fsSL "https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin trufflehog
fi

# ── gitleaks (binary) ─────────────────────────────────────────────────────────
if want gitleaks; then
  case "$ARCH" in amd64) GL_ARCH=x64 ;; *) GL_ARCH="$ARCH" ;; esac
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks
fi

# ── hermes-dec (pip, in its own venv — Debian's system Python is PEP 668) ─────
if want hermes-dec; then
  python3 -m venv /opt/hermes-dec
  /opt/hermes-dec/bin/pip install --no-cache-dir "$HERMES_DEC_SPEC"
  for b in hbc-file-parser hbc-disassembler hbc-decompiler; do
    ln -s "/opt/hermes-dec/bin/$b" "/usr/local/bin/$b"
  done
fi

# MobSF is never installed here — it runs as its own container.
echo "Tool install complete."
