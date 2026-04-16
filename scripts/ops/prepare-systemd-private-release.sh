#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Prepare a pinned private Sandbox Agent release for a systemd host.

This script does not require sudo. It:
  1. fetches the requested git ref from the private repo
  2. builds the `sandbox-agent` binary from that exact ref with the repo's Docker release builder
  3. installs it into a versioned release directory under ~/.local/opt/sandbox-agent/releases/
  4. updates ~/.local/opt/sandbox-agent/current
  5. renders a systemd unit and a root-only apply script

Usage:
  ./scripts/ops/prepare-systemd-private-release.sh --ref v0.4.2-ample.1

Options:
  --ref REF         Git ref to build, typically a private release tag. Required.
  --label LABEL     Release label directory name. Defaults to a filesystem-safe form of --ref.
  --target TARGET   Rust target to build. Defaults to the current host platform.
  --host HOST       Bind host for sandbox-agent server. Default: 0.0.0.0
  --port PORT       Bind port for sandbox-agent server. Default: 2468
  --user USER       systemd User=. Default: agent
  --group GROUP     systemd Group=. Default: agent
  --base-dir DIR    Install root. Default: $HOME/.local/opt/sandbox-agent
  --help            Show this help text.
EOF
}

REF=""
LABEL=""
TARGET=""
HOST="0.0.0.0"
PORT="2468"
SERVICE_USER="agent"
SERVICE_GROUP="agent"
BASE_DIR="${HOME}/.local/opt/sandbox-agent"

detect_target() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "${uname_s}:${uname_m}" in
    Linux:x86_64)
      printf '%s\n' "x86_64-unknown-linux-musl"
      ;;
    Linux:aarch64|Linux:arm64)
      printf '%s\n' "aarch64-unknown-linux-musl"
      ;;
    Darwin:x86_64)
      printf '%s\n' "x86_64-apple-darwin"
      ;;
    Darwin:arm64)
      printf '%s\n' "aarch64-apple-darwin"
      ;;
    *)
      echo "Unable to infer release target for ${uname_s}/${uname_m}; pass --target explicitly" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --label)
      LABEL="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --user)
      SERVICE_USER="${2:-}"
      shift 2
      ;;
    --group)
      SERVICE_GROUP="${2:-}"
      shift 2
      ;;
    --base-dir)
      BASE_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REF}" ]]; then
  echo "--ref is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "${TARGET}" ]]; then
  TARGET="$(detect_target)"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
SAFE_REF="$(printf '%s' "${REF}" | tr '/:@ ' '----')"
if [[ -z "${LABEL}" ]]; then
  LABEL="${SAFE_REF}"
fi

case "${TARGET}" in
  *windows*)
    echo "Windows targets are not supported by this systemd helper" >&2
    exit 1
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to build the pinned release artifact" >&2
  exit 1
fi

mkdir -p "${BASE_DIR}/releases" "${BASE_DIR}/worktrees" "${BASE_DIR}/systemd"

echo "==> Fetching ${REF} from origin"
git -C "${REPO_ROOT}" fetch origin --tags --prune
COMMIT="$(git -C "${REPO_ROOT}" rev-parse "${REF}^{commit}")"
SHORT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short "${COMMIT}")"

WORKTREE_DIR="${BASE_DIR}/worktrees/${SAFE_REF}-${SHORT_COMMIT}"
RELEASE_DIR="${BASE_DIR}/releases/${LABEL}"
UNIT_DIR="${BASE_DIR}/systemd"
UNIT_PATH="${UNIT_DIR}/sandbox-agent.service"
APPLY_PATH="${UNIT_DIR}/apply-sandbox-agent-systemd-release.sh"
METADATA_PATH="${RELEASE_DIR}/release-metadata.json"
CURRENT_LINK="${BASE_DIR}/current"
USER_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" ]]; then
  USER_HOME="/home/${SERVICE_USER}"
fi

cleanup() {
  if git -C "${REPO_ROOT}" worktree list --porcelain | grep -Fq "worktree ${WORKTREE_DIR}"; then
    git -C "${REPO_ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rm -rf "${WORKTREE_DIR}"

echo "==> Creating detached worktree at ${WORKTREE_DIR}"
git -C "${REPO_ROOT}" worktree add --detach "${WORKTREE_DIR}" "${COMMIT}"

echo "==> Building sandbox-agent from ${REF} (${SHORT_COMMIT}) for ${TARGET}"
(
  cd "${WORKTREE_DIR}"
  ./docker/release/build.sh "${TARGET}"
)

BINARY_SOURCE="${WORKTREE_DIR}/dist/sandbox-agent-${TARGET}"
if [[ ! -x "${BINARY_SOURCE}" ]]; then
  echo "Expected built binary not found at ${BINARY_SOURCE}" >&2
  exit 1
fi

mkdir -p "${RELEASE_DIR}/bin"
install -m 0755 "${BINARY_SOURCE}" "${RELEASE_DIR}/bin/sandbox-agent"

cat > "${METADATA_PATH}" <<EOF
{
  "ref": "${REF}",
  "label": "${LABEL}",
  "commit": "${COMMIT}",
  "shortCommit": "${SHORT_COMMIT}",
  "target": "${TARGET}",
  "builtAtUtc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "builtWith": "docker/release/build.sh",
  "repo": "git@github.com:amplemarket/sandbox-agent.git"
}
EOF

ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Ample Sandbox Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${USER_HOME}
Environment=SANDBOX_AGENT_ACP_REQUEST_TIMEOUT_MS=7200000
ExecStart=${CURRENT_LINK}/bin/sandbox-agent server --no-token --host ${HOST} --port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "${APPLY_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

install -D -m 0644 "${UNIT_PATH}" /etc/systemd/system/sandbox-agent.service
systemctl daemon-reload
systemctl restart sandbox-agent.service
systemctl status sandbox-agent.service --no-pager
EOF
chmod +x "${APPLY_PATH}"

echo
echo "Prepared private Sandbox Agent release"
echo "  ref:           ${REF}"
echo "  commit:        ${COMMIT}"
echo "  target:        ${TARGET}"
echo "  release dir:   ${RELEASE_DIR}"
echo "  current link:  ${CURRENT_LINK}"
echo "  unit file:     ${UNIT_PATH}"
echo "  root apply:    ${APPLY_PATH}"
echo
echo "Next step as root:"
echo "  sudo ${APPLY_PATH}"
