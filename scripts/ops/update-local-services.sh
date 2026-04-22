#!/usr/bin/env bash
# Update the local sandbox-agent + sherlock systemd services with the latest
# code from git, rebuild the sandbox-agent binary, force a fresh install of
# the Claude ACP adapter (so agents.rs string-replace patches apply), and
# restart both services. Idempotent — safe to re-run.
#
# Runs as root (for systemctl + swapping the binary path); drops privileges
# to ${SERVICE_USER:-agent} for all git/cargo/npm work.
#
# Usage:
#   sudo /home/agent/repos/sandbox-agent/scripts/ops/update-local-services.sh
#
# Env overrides:
#   SERVICE_USER           — user that owns the service processes (default: agent)
#   SANDBOX_AGENT_REPO     — path to sandbox-agent checkout
#   SHERLOCK_REPO          — path to sherlock checkout
#   SKIP_BUILD=1           — skip the cargo release build
#   SKIP_SHERLOCK=1        — don't touch sherlock (sandbox-agent only)
#   SKIP_PULL=1            — don't run git fetch / pull
set -euo pipefail

SERVICE_USER="${SERVICE_USER:-agent}"
USER_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
  echo "error: could not resolve home for user '${SERVICE_USER}'" >&2
  exit 1
fi

SANDBOX_AGENT_REPO="${SANDBOX_AGENT_REPO:-${USER_HOME}/repos/sandbox-agent}"
SHERLOCK_REPO="${SHERLOCK_REPO:-${USER_HOME}/repos/sherlock}"
SANDBOX_AGENT_BIN="${USER_HOME}/.local/opt/sandbox-agent/current/bin/sandbox-agent"
CLAUDE_ADAPTER_DIR="${USER_HOME}/.local/share/sandbox-agent/bin/agent_processes/claude"
SANDBOX_AGENT_HEALTH_URL="${SANDBOX_AGENT_HEALTH_URL:-http://127.0.0.1:2468/v1/health}"

log()  { printf '[update-services] %s\n' "$*"; }
warn() { printf '[update-services] WARN: %s\n' "$*" >&2; }
die()  { printf '[update-services] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  die "must run as root (use sudo)"
fi

as_user() {
  sudo -u "${SERVICE_USER}" -H bash -lc "$*"
}

# ---- preflight ------------------------------------------------------------
[[ -d "${SANDBOX_AGENT_REPO}" ]] || die "sandbox-agent repo not found at ${SANDBOX_AGENT_REPO}"
if [[ "${SKIP_SHERLOCK:-0}" != "1" ]]; then
  [[ -d "${SHERLOCK_REPO}" ]] || die "sherlock repo not found at ${SHERLOCK_REPO}"
fi
command -v systemctl >/dev/null || die "systemctl not found"

# ---- stop services --------------------------------------------------------
log "stopping services (if running)"
systemctl stop sherlock.service 2>/dev/null || true
systemctl stop sandbox-agent.service 2>/dev/null || true

# Belt-and-suspenders: kill stragglers that may be running outside systemd
# (old nohup dev-mode processes, orphaned Claude adapter subprocesses, etc.)
pkill -f "/bin/sandbox-agent server" 2>/dev/null || true
pkill -f "sandbox-agent/current/bin/sandbox-agent" 2>/dev/null || true
pkill -f "claude-agent-acp" 2>/dev/null || true
if [[ "${SKIP_SHERLOCK:-0}" != "1" ]]; then
  pkill -f "tsx watch src/index.ts" 2>/dev/null || true
  pkill -u "${SERVICE_USER}" -f "node .*sherlock/node_modules/.bin/tsx" 2>/dev/null || true
fi
sleep 1

# ---- pull latest code -----------------------------------------------------
if [[ "${SKIP_PULL:-0}" != "1" ]]; then
  log "pulling sandbox-agent"
  as_user "cd '${SANDBOX_AGENT_REPO}' && \
           branch=\$(git rev-parse --abbrev-ref HEAD) && \
           git fetch origin \"\$branch\" && \
           git pull --ff-only origin \"\$branch\""

  if [[ "${SKIP_SHERLOCK:-0}" != "1" ]]; then
    log "pulling sherlock"
    as_user "cd '${SHERLOCK_REPO}' && \
             branch=\$(git rev-parse --abbrev-ref HEAD) && \
             git fetch origin \"\$branch\" && \
             git pull --ff-only origin \"\$branch\""
  fi
fi

# ---- rebuild sandbox-agent release binary ---------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "building sandbox-agent (release)"
  as_user "source \$HOME/.cargo/env 2>/dev/null || true; \
           cd '${SANDBOX_AGENT_REPO}' && \
           cargo build --release -p sandbox-agent --bin sandbox-agent"

  NEW_BIN="${SANDBOX_AGENT_REPO}/target/release/sandbox-agent"
  [[ -x "${NEW_BIN}" ]] || die "built binary not found at ${NEW_BIN}"

  log "swapping sandbox-agent binary into ${SANDBOX_AGENT_BIN}"
  install -D -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0755 "${NEW_BIN}" "${SANDBOX_AGENT_BIN}"
else
  log "SKIP_BUILD=1 — leaving existing binary at ${SANDBOX_AGENT_BIN}"
fi

# ---- clear extracted adapter so agents.rs patches are reapplied -----------
# The Claude ACP adapter is installed via npm into the data dir on first
# session creation. If we leave the previous install in place, sandbox-agent
# reuses it and any updated string-replace patches in agents.rs won't take
# effect until the adapter happens to be re-extracted. Wiping the dir forces
# a clean re-install next time a Claude session is created.
if [[ -d "${CLAUDE_ADAPTER_DIR}" ]]; then
  log "clearing previously-extracted Claude adapter at ${CLAUDE_ADAPTER_DIR}"
  rm -rf "${CLAUDE_ADAPTER_DIR}"
fi

# ---- install sherlock deps if package.json changed -----------------------
if [[ "${SKIP_SHERLOCK:-0}" != "1" ]]; then
  log "ensuring sherlock deps"
  as_user "cd '${SHERLOCK_REPO}' && npm install --no-audit --no-fund --prefer-offline" || \
    warn "npm install returned non-zero — continuing, but sherlock may fail to start"
fi

# ---- reload + start services ---------------------------------------------
log "reloading systemd"
systemctl daemon-reload

log "starting sandbox-agent"
systemctl start sandbox-agent.service

log "waiting for sandbox-agent health at ${SANDBOX_AGENT_HEALTH_URL}"
for i in $(seq 1 60); do
  if curl -fsS --max-time 2 "${SANDBOX_AGENT_HEALTH_URL}" >/dev/null 2>&1; then
    log "sandbox-agent healthy after ${i}s"
    break
  fi
  sleep 1
  if [[ "${i}" -eq 60 ]]; then
    warn "sandbox-agent did not become healthy within 60s; status follows:"
    systemctl status sandbox-agent.service --no-pager || true
    die "aborting before starting sherlock"
  fi
done

if [[ "${SKIP_SHERLOCK:-0}" != "1" ]]; then
  log "starting sherlock"
  systemctl start sherlock.service
fi

# ---- report ---------------------------------------------------------------
log "final status:"
# shellcheck disable=SC2046
systemctl --no-pager --lines=3 status sandbox-agent.service \
  $([[ "${SKIP_SHERLOCK:-0}" != "1" ]] && echo sherlock.service) || true

log "done — installed sandbox-agent: $("${SANDBOX_AGENT_BIN}" --version 2>/dev/null || echo '(--version unsupported)')"
