#!/usr/bin/env bash
#
# Start the Docker daemon if it isn't already running, and wait until it
# answers.
#
# Why this exists: in a Claude Code web/app session the `docker` CLI and the
# compose plugin are both installed, but no daemon is running and
# /var/run/docker.sock does not exist. So the first `docker ps` fails with
#
#   Cannot connect to the Docker daemon at unix:///var/run/docker.sock.
#   Is the docker daemon running?
#
# which reads exactly like "Docker is unavailable in this environment" — and an
# agent that believes that stops, when every variant in this repo was one
# command away from booting.
#
# Idempotent and safe to run at the top of any script: if the daemon already
# answers, it returns immediately without starting a second one.
#
# Usage:
#   bin/bootstrap_docker.sh          # start and wait
#   bin/bootstrap_docker.sh --check  # report status only, start nothing
#
# Exit codes:
#   0  daemon is up and answering
#   1  daemon could not be started (message explains why)
#   2  --check was passed and the daemon is not running

set -euo pipefail

readonly LOG_FILE="${DOCKERD_LOG:-/tmp/dockerd.log}"
readonly WAIT_SECONDS="${DOCKERD_WAIT:-60}"

log() { printf '%s\n' "$*" >&2; }

daemon_responding() {
  docker info >/dev/null 2>&1
}

# `docker` and `docker compose` are separate installs — a machine can have the
# CLI without the compose plugin, and every variant here is compose-driven.
check_prerequisites() {
  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: no 'docker' CLI on PATH. This environment cannot run the testbed variants."
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log "WARNING: 'docker compose' plugin not found. The daemon may start, but"
    log "         'docker compose up' will not work."
  fi

  return 0
}

start_daemon() {
  if ! command -v dockerd >/dev/null 2>&1; then
    log "ERROR: the Docker daemon ('dockerd') is not installed, only the client."
    log "       This is a client-only environment — point DOCKER_HOST at a remote"
    log "       daemon, or run the variants somewhere else."
    return 1
  fi

  # Rootless dockerd exists, but nothing in this repo needs it and detecting it
  # properly is more surface than it's worth. Say so plainly instead.
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: starting dockerd needs root, and this shell is uid $(id -u)."
    log "       Re-run with sudo, or start the daemon out of band."
    return 1
  fi

  log "Starting dockerd (log: ${LOG_FILE})..."
  nohup dockerd >"${LOG_FILE}" 2>&1 &

  local waited=0
  while [ "${waited}" -lt "${WAIT_SECONDS}" ]; do
    if daemon_responding; then
      log "Docker daemon ready after ${waited}s."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  log "ERROR: dockerd did not answer within ${WAIT_SECONDS}s. Last 20 log lines:"
  tail -20 "${LOG_FILE}" >&2 || true
  return 1
}

main() {
  local check_only=0
  [ "${1:-}" = "--check" ] && check_only=1

  check_prerequisites || exit 1

  if daemon_responding; then
    log "Docker daemon already running."
    exit 0
  fi

  if [ "${check_only}" -eq 1 ]; then
    log "Docker daemon is NOT running. Run bin/bootstrap_docker.sh to start it."
    exit 2
  fi

  start_daemon || exit 1
}

main "$@"
