Adapt this RedBlue repo into "ApkScope": a sealed Docker environment where a LOCAL
LLM (Qwen via the Pi agent harness, github.com/earendil-works/pi) investigates a
DECOMPILED Android APK for security issues, with nothing leaving the machine.

KEEP from RedBlue:

- the Docker + docker-compose containment skeleton
- the internal Docker network + tinyproxy default-deny egress allowlist (ai-proxy/)
- non-root user, memory/resource caps
- the "validate before start / prove it's sealed" philosophy and the healthcheck idea
- the single-config-file design (you edit config, never the scripts)

DROP from RedBlue (does not apply to a compiled APK you're investigating — you WANT
the model to see everything in it, there is nothing of mine to hide from it):

- the entire red zone / blue zone source split, the rsync filter, the src/types
  interface-only trick, two-way sync, the shadow git repo, sync-in/sync-back, MR opening
- Claude Code, Anthropic OAuth, the Claude-specific image and prompts

ADD:

- A decompile pre-stage: input.apk -> apktool (manifest + smali + resources) AND
  jadx (readable Java) into a workspace dir. For React Native apks, also extract
  index.android.bundle and, if it's Hermes bytecode, run hermes-dec to recover JS.
- The Pi harness configured to use a LOCAL Qwen model served by a separate
  `ollama/ollama` container, reached over the internal network. No cloud providers,
  no API keys, pi-telemetry endpoint left unset.
- Optional MobSF container (opensecurity/mobile-security-framework-mobsf) for an
  automated scan; the harness can read its JSON report.
- Mount the apk and the decompiled output READ-ONLY for the model. Give it one
  writable /findings dir for its report only.
- Read the egress allowlist, tool selection, and LLM endpoint/model from the files
  the control-panel HTML page generates (ai-proxy/filter, tools.txt, llm.env).
- A healthcheck.sh that writes status.json (llm reachable, proxy up, each selected
  tool present) so the panel can show green checks.

IMAGES:

- harness/tools: node:22-bookworm-slim (Debian; apt installs Java/ripgrep/apktool
  cleanly, jadx/trufflehog drop in). NOT alpine.
- model: ollama/ollama
- scanner: opensecurity/mobile-security-framework-mobsf

NETWORK: investigation runs default-deny. The model endpoint is internal, so the
external allowlist can be empty by default. Pre-download everything (model weights,
MobSF deps, apktool framework files) during an online setup phase, then seal.

CONSTRAINTS: one config file drives it, non-root, fully offline-capable after setup.
Keep RRedBlue's validate-before-start gate: refuse to start if anything looks wrong.

- The LLM runs on the HOST, not in a container. The harness reaches it at
  http://host.docker.internal:11434 (add extra_hosts host-gateway on Linux).
  This is the ONE permitted host-ward route; the egress proxy/firewall must allow
  only host.docker.internal:11434 and otherwise stay default-deny. No model container.
