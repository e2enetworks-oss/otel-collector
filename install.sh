#!/usr/bin/env bash
# E2E Observability Agent — VM installer
# Usage:
#   E2E_API_KEY=<key> E2E_PROJECT_ID=<id> E2E_CUSTOMER_ID=<id> \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/e2enetworks-oss/otel-collector/main/install.sh)"

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
BINARY_NAME="e2e-otelcol"
BINARY_PATH="/usr/local/bin/${BINARY_NAME}"
CONFIG_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

CDN_BASE="https://observability.objectstore.e2enetworks.net/collector"
REGISTER_API="https://obs.e2enetworks.net/v1/install/register"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# ── Pure functions (unit-testable via bats) ──────────────────────────────────

# preflight: verify root, required tools, and required env vars.
preflight() {
  [ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."
  command -v curl      >/dev/null 2>&1 || error "curl is required but not installed."
  command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."

  [ -n "${E2E_API_KEY:-}"     ] || error "E2E_API_KEY is not set."
  [ -n "${E2E_PROJECT_ID:-}"  ] || error "E2E_PROJECT_ID is not set."
  [ -n "${E2E_CUSTOMER_ID:-}" ] || error "E2E_CUSTOMER_ID is not set."
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

  # Phase 2: Register with E2E Observability API
  info "Registering with E2E Observability API..."
  REGISTER_RESPONSE=$(curl -fsSL -X POST "${REGISTER_API}" \
    -H "Content-Type: application/json" \
    -d "{
      \"api_key\":      \"${E2E_API_KEY}\",
      \"project_id\":   ${E2E_PROJECT_ID},
      \"customer_id\":  ${E2E_CUSTOMER_ID},
      \"resource_type\": \"vm\"
    }") || error "Registration API call failed. Check your E2E_API_KEY and network connectivity."

  E2E_TOKEN=$(parse_field "${REGISTER_RESPONSE}" "ingestion_token")
  E2E_LOG_GROUP=$(parse_field "${REGISTER_RESPONSE}" "log_group")

  [ -n "${E2E_TOKEN:-}"     ] || error "Registration failed: ingestion_token missing. Check your credentials."
  [ -n "${E2E_LOG_GROUP:-}" ] || error "Registration failed: log_group missing. Check your credentials."

  info "Registered. Log group: ${E2E_LOG_GROUP}"

  # Phase 3: Download binary
  info "Downloading E2E OTel Collector binary (linux/${ARCH})..."
  local binary_url="${CDN_BASE}/e2e-otel-collector-linux-${ARCH}"
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

  # 4a. Env file (mode 600 — credentials)
  local host_name
  host_name=$(hostname -f 2>/dev/null || hostname)
  info "Writing env file to ${CONFIG_DIR}/env..."
  cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${host_name}
E2E_LOG_GROUP=${E2E_LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
EOF
  chmod 600 "${CONFIG_DIR}/env"

  # 4b. Collector config (fetched from CDN)
  info "Fetching collector config..."
  curl -fsSL -o "${CONFIG_DIR}/config.yaml" "${CDN_BASE}/vm-config.yaml" || \
    error "Failed to download vm-config.yaml from CDN."
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
