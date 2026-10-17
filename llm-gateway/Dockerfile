# ─────────────────────────────────────────────────────────────────────────────
# llm-gateway — the ONE permitted route out of the sealed network to the LLM.
#
# The LLM server (Ollama / LM Studio) runs on this host or on one machine on
# your private LAN. The harness sits on an internal network with no gateway,
# so it can reach neither, except through this container, which forwards
# exactly one TCP port to exactly one destination:
#
#     llm-gateway:8080  ──►  ${LLM_TARGET_HOST}:${LLM_TARGET_PORT}
#
# It is not a proxy: there is no way to ask it for a different host or port.
# The target is fixed at container start from llm.env (via apkscope.sh) and
# checked by validate.sh: host.docker.internal, or a private-LAN IP literal.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache socat

USER nobody
EXPOSE 8080

ENV LLM_TARGET_HOST=host.docker.internal LLM_TARGET_PORT=11434
CMD ["sh", "-c", "exec socat TCP-LISTEN:8080,fork,reuseaddr TCP:${LLM_TARGET_HOST}:${LLM_TARGET_PORT}"]
