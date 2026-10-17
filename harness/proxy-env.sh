# Sourced via BASH_ENV by every non-interactive bash the model's tools spawn.
#
# Pi itself is deliberately NOT given proxy variables: its only destination is
# llm-gateway on the internal network, and some HTTP clients ignore NO_PROXY.
# The shell commands the model runs, however, go through the allowlist proxy,
# so `curl https://<allowlisted host>` works and everything else gets a 403.
export HTTP_PROXY=http://egress-proxy:8888
export HTTPS_PROXY=http://egress-proxy:8888
export http_proxy=http://egress-proxy:8888
export https_proxy=http://egress-proxy:8888
export NO_PROXY=llm-gateway
export no_proxy=llm-gateway
