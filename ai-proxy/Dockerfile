# ─────────────────────────────────────────────────────────────────────────────
# Egress allowlist proxy. tinyproxy forwards ONLY to hosts listed in `filter`
# (empty by default). The harness has no other way to the internet, so this is
# the single, auditable external egress point.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter         /etc/tinyproxy/filter

EXPOSE 8888

# tinyproxy drops to the unprivileged `tinyproxy` user itself (User/Group in
# tinyproxy.conf). -d keeps it in the foreground.
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
