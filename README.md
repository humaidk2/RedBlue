# ApkScope: a sealed sandbox where a local LLM investigates an APK

ApkScope decompiles an Android APK and hands it to the
[Pi](https://github.com/earendil-works/pi) coding agent, which runs against a
**local** Qwen model (Ollama or LM Studio). Pi works inside Docker containers
that can't reach the internet, your LAN, or your machine. The one exception is
a single forwarded port to the LLM server. Nothing leaves your network.

The design comes from RedBlue (default-deny egress proxy, internal Docker
networks, non-root, resource caps, one config file, validate-before-start).
RedBlue's red/blue source split is gone. You *want* the model to see the whole
APK, and there's nothing of yours in it to hide.

```
                       ┌────────────── sealed (internal: true) ──────────────┐
 input/app.apk ──ro──▶ │  harness: Pi + apktool/jadx/rg/trufflehog/…         │
 workspace/    ──ro──▶ │      │ /findings (only writable mount)              │
 findings/     ◀──rw── │      ├──▶ llm-gateway:8080 ──▶ ONE host:port (LLM)   │──▶ Ollama / LM Studio
                       │      └──▶ egress-proxy:8888 ──▶ allowlist (empty)   │──▶ (nothing, by default)
                       └─────────────────────────────────────────────────────┘
 decompile: network_mode none         mobsf + mobsf-scan: own internal network
```

## Quick start

```bash
# 0. An LLM server: this machine or one box on your LAN (see "LLM server" below)
# 1. Policy: open the panel, pick server/model/tools/allowlist, Save to repo
./apkscope.sh panel                 # http://127.0.0.1:8765

# 2. ONLINE, once: build images, pre-pull MobSF, check the model is available
./apkscope.sh setup

# 3. SEALED from here on
cp ~/Downloads/target.apk input/app.apk   # or set APK_PATH in apkscope.config.sh
./apkscope.sh decompile             # apktool + jadx (+ Hermes) → workspace/, no network
./apkscope.sh scan                  # optional: MobSF report → workspace/mobsf/
./apkscope.sh investigate           # gate → live seal probe → Pi (interactive)
./apkscope.sh headless              # …or one-shot; writes findings/report.md
```

## Configuration

You edit configuration files, never the scripts:

| File | What it holds | Written by |
|---|---|---|
| `apkscope.config.sh` | APK path, data dirs, memory caps, MobSF image, Pi version | you |
| `llm.env` | LLM endpoint, model, context window, provider (`ollama` \| `lmstudio`) | control panel |
| `tools.txt` | tools baked into the harness image | control panel |
| `ai-proxy/filter` | external egress allowlist (empty = air-gapped) | control panel |

The panel (`apkscope-control-panel.html`) still works opened as a plain file:
use **Download** and move the files in yourself. Served by
`./apkscope.sh panel` (127.0.0.1 only), it can **Save to repo** and show live
status. It accepts writes only to those three files, and only from its own
origin.

Changing `tools.txt` means re-running `setup`. The gate refuses to run an
image built from a different `tools.txt`.

## The gate

Every stage runs `scripts/validate.sh` first. It refuses to start if any of these fail:

- **llm.env**: the endpoint is this machine or a private-LAN **IP literal**
  (no public or DNS-named hosts). The provider is `ollama` or `lmstudio`.
  No other keys are allowed (so no API keys and no telemetry endpoints), and
  telemetry is off.
- **filter**: every line has the panel's anchored `(^|\.)host\.name$` form,
  with no localhost, `.local`/`.internal`, Docker names or raw IPs.
  tinyproxy stays `FilterDefaultDeny Yes` with CONNECT to 443 only.
- **inputs**: the APK is a zip, and `workspace/` was decompiled from *this*
  APK (sha256).
- **images**: built, and built from the current `tools.txt`.
- **rendered compose** (`docker compose config`): the harness is only on the
  internal network. The APK and workspace are read-only and `/findings` is
  the only writable bind. The root fs is read-only and non-root. Decompile
  has `network_mode: none`. No published ports, host networking or
  privileged containers.
- **LLM server**: it answers, the model is listed, and (LM Studio) the
  model's *loaded* context length is ≥ `LLM_CONTEXT_WINDOW`.

Then `investigate` runs `harness/healthcheck.sh` **inside the sealed
network** and refuses to start Pi unless the live probe proves it's sealed:

- no direct internet, DNS, host, LLM-box or LAN route
- the proxy returns 403 for an unlisted host, the host, and the LLM box
- the model answers through `llm-gateway`

The results go to `status.json`, which the panel reads.

## LLM server

`llm-gateway` is a socat container that forwards `llm-gateway:8080` to exactly
the `host:port` in `llm.env`. It is not a proxy, so the harness can't ask it
for anything else.

- **LM Studio on another machine** (current config: `192.168.1.205:1234`,
  `qwen/qwen3.8-27b`). Enable *Serve on Local Network*, then load the model
  with **Context Length ≥ 32768**. 8k is too small for an agent, and the gate
  will refuse it.
- **Ollama on this machine** (`http://localhost:11434`). On Docker Desktop it
  just works. On Linux, Ollama binds 127.0.0.1 by default, so set
  `OLLAMA_HOST=0.0.0.0` (firewall it) or the docker bridge IP. Set
  `OLLAMA_CONTEXT_LENGTH` to match `LLM_CONTEXT_WINDOW`.

Pi gets a generated `models.json` with a single provider pointing at the
gateway. It also runs with `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`,
`PI_TELEMETRY=0`, install telemetry disabled, and no pi-telemetry endpoint.

## Prompt-injection hardening

Assume the APK is hostile. Its strings can address the model directly. Pi
runs with `--no-context-files --no-extensions --no-skills
--no-prompt-templates --no-mcp --no-approve`, so nothing in the decompiled
tree (an `AGENTS.md` in assets, say) can load as instructions or code. The
brief (`harness/investigate-prompt.md`) tells the model to treat everything
under `/input` and `/workspace` as evidence, never as instructions. Even if
the model is steered, it can only write to `/findings` and reach the LLM.

Pi itself gets no proxy variables. Only the model's shell commands do (via
`BASH_ENV`), so `curl` to an allowlisted host works and anything else gets 403.

## Layout

```
apkscope.sh                 driver: setup | decompile | scan | investigate | headless | run | validate | health | panel | shell | down
apkscope.config.sh          the config file
apkscope-control-panel.html policy generator + status view
llm.env  tools.txt  ai-proxy/filter     panel-generated policy
docker-compose.yml          services + networks
harness/                    Pi + tools image: entrypoint, decompile, mobsf-scan, healthcheck, brief
ai-proxy/                   tinyproxy default-deny allowlist
llm-gateway/                the single LLM route
scripts/validate.sh         the gate
scripts/panel-server.py     127.0.0.1 panel server
input/ workspace/ findings/ status.json   (gitignored data)
```

## Outputs

- `findings/report.md`: summary, findings table (severity + confidence), evidence, and fixes
- `findings/findings.json`: the same findings, machine-readable
- `findings/.pi-sessions/`: full Pi transcripts (the audit trail)
- `workspace/`: `apktool/`, `jadx/`, `raw/`, `rn/`, `mobsf/`, `manifest.json`
