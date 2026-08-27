#!/usr/bin/env bash
# E2E Observability Agent — VM installer
# Usage:
#   E2E_API_KEY=<key> \
#   E2E_REGISTER_API=http://<obs-api-host>:31881/v1/install/register \
#   E2E_GATEWAY_ENDPOINT=<gateway-host>:31318 \
#     bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
BINARY_NAME="e2e-otelcol"
BINARY_PATH="/usr/local/bin/${BINARY_NAME}"
CONFIG_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Published install assets (install.sh, samples/, mirrored release binaries) are
# served from GitHub Pages — see .github/workflows/pages.yaml.
PAGES_BASE="https://e2enetworks-oss.github.io/otel-collector"

# ── Endpoints ────────────────────────────────────────────────────────────────
# Both are deployment-specific and have no safe default — set them for your
# environment, or pass them as env vars at install time.
#
# E2E_REGISTER_API   The observability-api REST service. Serves
#                    POST /v1/install/register, which exchanges the API key for
#                    an ingestion token, project_id, and log_group.
#                    Deployed as the `rest` port of the observability-api
#                    Service (NodePort 31881 in the reference deployment).
#                    Example: http://<obs-api-host>:31881/v1/install/register
#
# E2E_GATEWAY_ENDPOINT
#                    The otel-gateway OTLP/gRPC listener that the agent ships
#                    telemetry to. Host:port only — no scheme, no path.
#                    Port 4317 on the Service (NodePort 31318 in the reference
#                    deployment).
#                    Example: <gateway-host>:31318
REGISTER_API="${E2E_REGISTER_API:-}"
GATEWAY_ENDPOINT="${E2E_GATEWAY_ENDPOINT:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# ── Pure functions (unit-testable via bats) ──────────────────────────────────

# preflight: verify root, required tools, and required env vars.
preflight() {
  [ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."
  command -v curl      >/dev/null 2>&1 || error "curl is required but not installed."
  command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."

  [ -n "${E2E_API_KEY:-}" ] || error "E2E_API_KEY is not set."

  # Endpoints are deployment-specific — fail loudly rather than guessing.
  [ -n "${REGISTER_API:-}" ] || error \
    "E2E_REGISTER_API is not set. Point it at the observability-api register endpoint, e.g. http://<obs-api-host>:31881/v1/install/register"
  [ -n "${GATEWAY_ENDPOINT:-}" ] || error \
    "E2E_GATEWAY_ENDPOINT is not set. Point it at the otel-gateway OTLP/gRPC listener as host:port, e.g. <gateway-host>:31318"
}

# detect_arch: map `uname -m` to the Go arch string. Echoes amd64|arm64, or
# exits with an error on unsupported platforms.
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) error "Unsupported architecture: $machine. Only x86_64 and aarch64 are supported." ;;
  esac
}

# parse_field <json> <field>: extract a top-level string field from a JSON
# object. Uses jq when available, falls back to grep/cut otherwise. Echoes the
# value or an empty string when the field is absent.
parse_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r ".${field} // empty"
  else
    # `|| true` so a missing field (grep no-match → exit 1) doesn't trip
    # pipefail/set -e in the caller before the friendly error check runs.
    echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | cut -d'"' -f4 || true
  fi
}

# ── Main install flow ─────────────────────────────────────────────────────────
main() {
  # Phase 0: Preflight
  info "Running preflight checks..."
  preflight
  info "Preflight passed."

  # Phase 1: Detect platform
  info "Detecting platform..."
  ARCH=$(detect_arch)
  OS_ID=""
  # shellcheck source=/dev/null
  [ -f /etc/os-release ] && OS_ID=$(. /etc/os-release && echo "${ID:-unknown}")
  info "Platform: linux/${ARCH} (${OS_ID:-unknown distro})"

  # hostname is sent so the server derives a per-host log group
  # (logs.infra.vm.<project_id>.<host>). Sanitized to characters that are
  # safe inside a JSON string; the server re-sanitizes for group naming.
  local host_name
  host_name=$(hostname -f 2>/dev/null || hostname)
  host_name=${host_name//[^a-zA-Z0-9.-]/}

  # Phase 2: Register with E2E Observability API
  info "Registering with E2E Observability API (host: ${host_name})..."
  REGISTER_RESPONSE=$(curl -fsSL -X POST "${REGISTER_API}" \
    -H "Content-Type: application/json" \
    -d "{
      \"apiKey\":       \"${E2E_API_KEY}\",
      \"resourceType\": \"vm\",
      \"hostname\":     \"${host_name}\"
    }") || error "Registration API call failed. Check your E2E_API_KEY and network connectivity."

  E2E_TOKEN=$(parse_field "${REGISTER_RESPONSE}" "ingestion_token")
  E2E_LOG_GROUP=$(parse_field "${REGISTER_RESPONSE}" "log_group")
  E2E_PROJECT_ID=$(parse_field "${REGISTER_RESPONSE}" "project_id")

  [ -n "${E2E_TOKEN:-}"     ] || error "Registration failed: ingestion_token missing. Check your credentials."
  [ -n "${E2E_LOG_GROUP:-}" ] || error "Registration failed: log_group missing. Check your credentials."
  [ -n "${E2E_PROJECT_ID:-}" ] || error "Registration failed: project_id missing. Check your credentials."

  info "Registered. Log group: ${E2E_LOG_GROUP}"

  # Phase 3: Download binary
  info "Downloading E2E OTel Collector binary (linux/${ARCH})..."
  local binary_url="${PAGES_BASE}/e2e-otel-collector-linux-${ARCH}"
  local binary_tmp="${BINARY_PATH}.tmp"

  mkdir -p "$(dirname "${BINARY_PATH}")"

  curl -fsSL --progress-bar -o "${binary_tmp}" "${binary_url}" || \
    error "Binary download failed from ${binary_url}. Please try again or contact E2E support."

  chmod +x "${binary_tmp}"
  mv "${binary_tmp}" "${BINARY_PATH}"
  info "Binary installed at ${BINARY_PATH}"

  # Phase 4: Write config, env file, and service
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/tmp"
  chmod 755 "${CONFIG_DIR}"
  chmod 700 "${DATA_DIR}"

  # 4a. Env file (mode 600 — credentials). host_name was computed and
  # sanitized before registration so both use the same value.
  info "Writing env file to ${CONFIG_DIR}/env..."
  cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${host_name}
E2E_LOG_GROUP=${E2E_LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
E2E_GATEWAY_ENDPOINT=${GATEWAY_ENDPOINT}
EOF
  chmod 600 "${CONFIG_DIR}/env"

  # 4b. Collector config (fetched from GitHub Pages)
  info "Fetching collector config..."
  curl -fsSL -o "${CONFIG_DIR}/config.yaml" "${PAGES_BASE}/samples/vm-config.yaml" || \
    error "Failed to download vm-config.yaml from ${PAGES_BASE}/samples/vm-config.yaml."
  chmod 644 "${CONFIG_DIR}/config.yaml"

  # 4c. Systemd service unit
  info "Installing systemd service..."
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=E2E Observability Agent
Documentation=https://github.com/e2enetworks-oss/otel-collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${CONFIG_DIR}/env
ExecStart=${BINARY_PATH} --config=${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

  # Start service
  info "Enabling and starting ${SERVICE_NAME}..."
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    systemctl restart "${SERVICE_NAME}"
    info "Service restarted."
  else
    systemctl start "${SERVICE_NAME}"
    info "Service started."
  fi

  # Done
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " E2E Observability Agent installed successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Host:      ${host_name}"
  echo " Log group: ${E2E_LOG_GROUP}"
  echo " Project:   ${E2E_PROJECT_ID}"
  echo ""
  echo " Status:    systemctl status ${SERVICE_NAME}"
  echo " Logs:      journalctl -u ${SERVICE_NAME} -f"
  echo " Health:    curl -s http://localhost:13133"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Run main only when executed directly — not when sourced by tests (bats).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
