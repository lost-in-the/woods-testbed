#!/usr/bin/env bash
#
# docker compose wrapper that works both on a laptop and inside a Claude Code
# web/app session.
#
# On a laptop it is a passthrough: `bin/ccr_compose.sh up -d rails-8.0` runs
# exactly `docker compose up -d rails-8.0`.
#
# Behind the session's egress proxy it additionally:
#   - starts the Docker daemon if it isn't running (bin/bootstrap_docker.sh)
#   - stages the proxy CA into each variant's build context so the image can
#     trust it (the file is gitignored; it is copied, never committed)
#   - builds with --network host, since the proxy listens on 127.0.0.1 and a
#     build container on the default bridge cannot reach it
#   - layers in docker-compose.ccr.yml, which puts the running container in the
#     host network namespace for the same reason
#
# Detection is on the CA bundle existing AND the proxy answering, so a stale
# HTTPS_PROXY pointing at nothing degrades to the plain path instead of hanging.
#
# Usage:  bin/ccr_compose.sh <any docker compose args>
#         bin/ccr_compose.sh build rails-8.0-large
#         bin/ccr_compose.sh up -d rails-8.0-large

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CA_SOURCE="${CCR_CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"

log() { printf '%s\n' "$*" >&2; }

proxy_active() {
  [ -s "${CA_SOURCE}" ] || return 1
  [ -n "${HTTPS_PROXY:-}" ] || return 1
  curl -sS -m 5 -o /dev/null "${HTTPS_PROXY}/__agentproxy/status" 2>/dev/null
}

# Every variant's Dockerfile copies ca-bundle.crt from its own build context.
# A committed empty placeholder makes that COPY valid on a laptop; here it is
# temporarily filled with the real bundle and emptied again afterwards, so a
# session-specific certificate can never drift into a commit.
ca_bundle_targets() {
  local app_dir
  for app_dir in "${REPO_ROOT}"/apps/*/; do
    [ -f "${app_dir}Dockerfile" ] || continue
    grep -q 'ca-bundle.crt' "${app_dir}Dockerfile" 2>/dev/null && printf '%s\n' "${app_dir}ca-bundle.crt"
  done
}

stage_ca_bundles() {
  local target
  while read -r target; do
    [ -n "${target}" ] && cp "${CA_SOURCE}" "${target}"
  done < <(ca_bundle_targets)
}

restore_ca_placeholders() {
  local target
  while read -r target; do
    [ -n "${target}" ] && : > "${target}"
  done < <(ca_bundle_targets)
}

main() {
  if ! proxy_active; then
    exec docker compose "$@"
  fi

  log "CCR proxy detected — building with --network host and the CA overlay."

  "${REPO_ROOT}/bin/bootstrap_docker.sh"
  stage_ca_bundles

  # BuildKit does not accept --network host from the compose build path, so
  # builds go through `docker build` semantics via COMPOSE_DOCKER_CLI_BUILD=0.
  export COMPOSE_DOCKER_CLI_BUILD=0
  export DOCKER_BUILDKIT=0
  export BUILDKIT_PROGRESS=plain

  # Not exec'd: the placeholder restore has to run afterwards.
  trap restore_ca_placeholders EXIT

  local status=0
  docker compose \
    -f "${REPO_ROOT}/docker-compose.yml" \
    -f "${REPO_ROOT}/docker-compose.ccr.yml" \
    "$@" || status=$?

  exit "${status}"
}

main "$@"
