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
BINARY_RELEASE_NAME="e2e-otel-collector-linux"
REGISTER_API="https://obs.e2enetworks.net/v1/install/register"
FALLBACK_BINARY_VERSION="0.152.1"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# ── Phase 0: Preflight ───────────────────────────────────────────────────────
info "Running preflight checks..."

[ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."
command -v curl     >/dev/null 2>&1 || error "curl is required but not installed."
command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."

[ -n "${E2E_API_KEY:-}"     ] || error "E2E_API_KEY is not set."
[ -n "${E2E_PROJECT_ID:-}"  ] || error "E2E_PROJECT_ID is not set."
[ -n "${E2E_CUSTOMER_ID:-}" ] || error "E2E_CUSTOMER_ID is not set."

info "Preflight passed."

# ── Phase 1: Detect Platform ─────────────────────────────────────────────────
info "Detecting platform..."

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) error "Unsupported architecture: $ARCH. Only x86_64 and aarch64 are supported." ;;
esac

OS_ID=""
[ -f /etc/os-release ] && OS_ID=$(. /etc/os-release && echo "${ID:-unknown}")
info "Platform: linux/${ARCH} (${OS_ID:-unknown distro})"

# ── Phase 2: Register with E2E Observability API ─────────────────────────────
info "Registering with E2E Observability API..."

REGISTER_RESPONSE=$(curl -fsSL -X POST "${REGISTER_API}" \
  -H "Content-Type: application/json" \
  -d "{
    \"api_key\":      \"${E2E_API_KEY}\",
    \"project_id\":   ${E2E_PROJECT_ID},
    \"customer_id\":  ${E2E_CUSTOMER_ID},
    \"resource_type\": \"vm\"
  }") || error "Registration API call failed. Check your E2E_API_KEY and network connectivity."

E2E_TOKEN=$(echo "${REGISTER_RESPONSE}"   | grep -o '"ingestion_token":"[^"]*"' | cut -d'"' -f4)
E2E_LOG_GROUP=$(echo "${REGISTER_RESPONSE}" | grep -o '"log_group":"[^"]*"'       | cut -d'"' -f4)

[ -n "${E2E_TOKEN:-}"     ] || error "Registration succeeded but ingestion_token was empty. Response: ${REGISTER_RESPONSE}"
[ -n "${E2E_LOG_GROUP:-}" ] || error "Registration succeeded but log_group was empty. Response: ${REGISTER_RESPONSE}"

info "Registered. Log group: ${E2E_LOG_GROUP}"

# ── Phase 3: Download Binary ──────────────────────────────────────────────────
info "Downloading OTel Collector binary (linux/${ARCH})..."

BINARY_URL="${CDN_BASE}/e2e-otel-collector-linux-${ARCH}"
BINARY_TMP="${BINARY_PATH}.tmp"

mkdir -p "$(dirname "${BINARY_PATH}")"

if ! curl -fsSL --progress-bar -o "${BINARY_TMP}" "${BINARY_URL}"; then
  info "CDN download failed, falling back to upstream otelcol-contrib v${FALLBACK_BINARY_VERSION}..."
  FALLBACK_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${FALLBACK_BINARY_VERSION}/otelcol-contrib_${FALLBACK_BINARY_VERSION}_linux_${ARCH}.tar.gz"
  FALLBACK_TMP=$(mktemp -d)
  curl -fsSL --progress-bar -o "${FALLBACK_TMP}/otelcol.tar.gz" "${FALLBACK_URL}" || \
    error "Both CDN and upstream fallback download failed."
  tar -xzf "${FALLBACK_TMP}/otelcol.tar.gz" -C "${FALLBACK_TMP}"
  cp "${FALLBACK_TMP}/otelcol-contrib" "${BINARY_TMP}"
  rm -rf "${FALLBACK_TMP}"
fi

chmod +x "${BINARY_TMP}"
mv "${BINARY_TMP}" "${BINARY_PATH}"
info "Binary installed at ${BINARY_PATH}"

# ── Phase 4: Write Config, Env File, and Service ─────────────────────────────

# Create directories
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/tmp"
chmod 755 "${CONFIG_DIR}"
chmod 700 "${DATA_DIR}"

# 4a. Env file (mode 600 — credentials)
HOST_NAME=$(hostname -f 2>/dev/null || hostname)
info "Writing env file to ${CONFIG_DIR}/env..."
cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${HOST_NAME}
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

# ── Start Service ─────────────────────────────────────────────────────────────
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

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " E2E Observability Agent installed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Host:      ${HOST_NAME}"
echo " Log group: ${E2E_LOG_GROUP}"
echo " Project:   ${E2E_PROJECT_ID}"
echo ""
echo " Status:    systemctl status ${SERVICE_NAME}"
echo " Logs:      journalctl -u ${SERVICE_NAME} -f"
echo " Health:    curl -s http://localhost:13133"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
