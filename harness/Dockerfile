# ─────────────────────────────────────────────────────────────────────────────
# ApkScope harness: Pi coding agent + the APK analysis tools from tools.txt.
#
# Pi has no official image; this follows its containerization doc
# (bookworm-slim + `npm install -g --ignore-scripts`) but runs non-root and
# carries no provider credentials — the only model is the local one.
#
# Built during `./apkscope.sh setup` (online). Everything the investigation
# needs is baked in here; at run time the container is sealed.
# Build context is the repo root (so tools.txt is visible) — see .dockerignore.
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim

ARG PI_VERSION=latest
ARG TOOLS_SHA=unset
LABEL apkscope.tools_sha="${TOOLS_SHA}"

# Base utilities the scripts and the model rely on.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl jq file git less procps \
 && rm -rf /var/lib/apt/lists/*

# Pi coding agent. --ignore-scripts per Pi's own install instructions.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# Analysis tools, exactly as selected in tools.txt.
COPY tools.txt /opt/apkscope/tools.txt
COPY harness/install-tools.sh /opt/apkscope/install-tools.sh
RUN bash /opt/apkscope/install-tools.sh /opt/apkscope/tools.txt

# Runtime scripts + the investigation brief.
COPY harness/entrypoint.sh harness/decompile.sh harness/mobsf-scan.sh \
     harness/healthcheck.sh harness/investigate-prompt.md harness/proxy-env.sh \
     /opt/apkscope/
RUN chmod 0755 /opt/apkscope/*.sh

# Non-root user. compose overrides the uid/gid with the host's so files in
# workspace/ and findings/ come out owned by you; HOME and Pi's agent dir live
# on a tmpfs, so any uid works and nothing persists between runs.
RUN groupadd -g 10001 apkscope && useradd -u 10001 -g apkscope -M -d /tmp/home -s /bin/bash apkscope
USER apkscope

# user.home: the compose uid has no passwd entry, so Java would otherwise use
# "?" relative to the cwd — i.e. write jadx/apktool caches into /workspace.
ENV HOME=/tmp/home \
    JAVA_TOOL_OPTIONS="-Duser.home=/tmp/home" \
    PI_CODING_AGENT_DIR=/tmp/pi-agent \
    PI_CODING_AGENT_SESSION_DIR=/findings/.pi-sessions \
    PI_OFFLINE=1 \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0

WORKDIR /workspace
ENTRYPOINT ["/opt/apkscope/entrypoint.sh"]
CMD ["investigate"]
