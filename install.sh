#!/usr/bin/env bash
# E2E Observability Agent — VM installer
# Usage:
#   E2E_API_KEY=<key> \
#     bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
#
# That installs against production. To install against a dev stack, add E2E_SITE
# — see the Endpoints block below for that and the per-endpoint overrides:
#   E2E_API_KEY=<key> E2E_SITE=api-groot.e2enetworks.net \
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
# E2E_API_KEY is the only value a customer supplies; everything below defaults
# to production. The overrides exist for engineers installing against one of the
# dev deployments, and each is narrower than the one before it:
#
# E2E_SITE           The deployment to install against — hostname only, no
#                    scheme and no port. Both endpoints derive from it, so this
#                    is the single knob a dev environment normally needs.
#                    Default: production. Example: api-groot.e2enetworks.net
#
# E2E_REGISTER_API   Full register URL, for a deployment that does not follow
#                    the derived shape — a NodePort, say. Serves
#                    POST /v1/install/register, which exchanges the API key for
#                    an ingestion token, project_id, and log_group (the `rest`
#                    port of the observability-api Service, NodePort 31881 in
#                    the reference deployment).
#                    Example: http://10.0.0.5:31881/v1/install/register
#
# E2E_GATEWAY_ENDPOINT
#                    The otel-gateway OTLP/gRPC listener the agent ships
#                    telemetry to. Host:port only — no scheme, no path. Port
#                    4317 on the Service, NodePort 31318 in the reference
#                    deployment. Example: 10.0.0.5:31318
#
# Shaped after Datadog's DD_SITE: one variable selects the environment, and the
# per-endpoint variables stay as escape hatches for what it cannot express.
DEFAULT_SITE="obs.e2enetworks.net"
GATEWAY_PORT="31318"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# Bounds for the small control-plane calls — register, checksums.txt, the
# collector config. Each is a few KB, so a 120s ceiling on the whole request is
# generous, and it catches the half-open route that otherwise hangs an install
# forever with no error. Retries cover a single blip on a customer network.
# No --proto-redir on purpose: E2E_REGISTER_API is documented as http for the
# NodePort deployment, so pinning redirects to https would break it.
CURL_OPTS=(--fail --silent --show-error --location
           --connect-timeout 10 --max-time 120
           --retry 3 --retry-delay 2 --retry-connrefused)

# The binary is ~210 MB and deliberately gets NO --max-time: a 120s ceiling
# aborts every install on a link slower than ~15 Mbit/s, then burns three
# retries doing it again. A stalled transfer is caught by throughput instead —
# give up only when less than 1 KB/s moves for 60s, which bounds a hang without
# punishing a slow but working link. --silent is dropped so --progress-bar can
# actually render; curl suppresses the bar entirely under --silent.
CURL_DOWNLOAD_OPTS=(--fail --show-error --location --progress-bar
                    --connect-timeout 10
                    --speed-limit 1024 --speed-time 60
                    --retry 3 --retry-delay 2 --retry-connrefused)

# Temp downloads are removed on every exit path, so a failed install never
# leaves a partial binary behind in a directory on PATH.
TMP_FILES=()
cleanup() { [ ${#TMP_FILES[@]} -eq 0 ] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT

# ── Pure functions (unit-testable via bats) ──────────────────────────────────

# resolve_endpoints: fill SITE, REGISTER_API, GATEWAY_ENDPOINT and
# GATEWAY_DERIVED from the environment. Precedence runs narrowest first — an
# explicit per-endpoint override, then E2E_SITE, then production. Sets globals
# rather than echoing because it resolves four values; bats drives it with an
# environment and reads them back.
resolve_endpoints() {
  SITE="${E2E_SITE:-${DEFAULT_SITE}}"
  REGISTER_API="${E2E_REGISTER_API:-https://${SITE}/v1/install/register}"
  GATEWAY_ENDPOINT="${E2E_GATEWAY_ENDPOINT:-${SITE}:${GATEWAY_PORT}}"

  # Whether the gateway was derived or supplied decides how hard we check it
  # below: a value the operator typed is their claim to make, a value this
  # script guessed has to prove itself before we ship telemetry at it.
  if [ -n "${E2E_GATEWAY_ENDPOINT:-}" ]; then
    GATEWAY_DERIVED="no"
  else
    GATEWAY_DERIVED="yes"
  fi
}

# gateway_reachable <host:port>: succeed when a TCP connection opens inside 5s.
# Returns 0 when the check cannot run at all (no `timeout`), because an absent
# tool is not evidence of an unreachable gateway.
gateway_reachable() {
  local hostport="$1" host port
  host="${hostport%:*}"
  port="${hostport##*:}"
  command -v timeout >/dev/null 2>&1 || return 0
  timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# preflight: verify root, required tools, the API key, and endpoint shape.
preflight() {
  [ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."
  command -v curl      >/dev/null 2>&1 || error "curl is required but not installed."
  command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || \
    error "Neither sha256sum nor shasum found — the downloaded binary could not be verified."

  # The only value with no default. Everything else falls back to production.
  [ -n "${E2E_API_KEY:-}" ] || error "E2E_API_KEY is not set."

  # A scheme on the gateway is the common mistake: it is an OTLP/gRPC dial
  # target, not a URL, and the collector fails obscurely later if one leaks in.
  case "${GATEWAY_ENDPOINT}" in
    *://*) error "E2E_GATEWAY_ENDPOINT must be host:port with no scheme (got '${GATEWAY_ENDPOINT}')." ;;
    *:*)   : ;;
    *)     error "E2E_GATEWAY_ENDPOINT must include a port, as host:port (got '${GATEWAY_ENDPOINT}')." ;;
  esac
}

# check_gateway: an unreachable gateway does not stop the collector — the
# service stays active, retries each batch for five minutes and then drops it,
# so the only symptom is missing data. Refuse to finish an install that would
# land in that state on an endpoint nobody chose. An endpoint the operator
# passed explicitly only warns: their network may open after install.
check_gateway() {
  info "Checking the gateway is reachable (${GATEWAY_ENDPOINT})..."
  if gateway_reachable "${GATEWAY_ENDPOINT}"; then
    info "Gateway reachable."
    return 0
  fi
  if [ "${GATEWAY_DERIVED}" = "yes" ]; then
    error "Cannot reach the default gateway ${GATEWAY_ENDPOINT}. This host may be \
outside the E2E internal network, or this deployment may use a different gateway. \
Set E2E_SITE for your environment, or E2E_GATEWAY_ENDPOINT=<host>:<port> for the \
gateway directly, then re-run. Installing now would collect telemetry and drop it."
  fi
  info "WARNING: ${GATEWAY_ENDPOINT} is not reachable from this host right now. \
Continuing because you set it explicitly — until it opens, the agent collects \
and drops telemetry with no error beyond the service journal."
}

# sha256_of <file>: echo the file's sha256, using whichever tool the distro ships.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# checksum_for <checksums-text> <filename>: echo the published sha256 for that
# file, or nothing when it is not listed. Pure, so bats covers the parsing.
checksum_for() {
  echo "$1" | awk -v n="$2" '$2 == n { print $1; exit }'
}

# verify_binary <file> <published-name>: refuse to install anything whose digest
# does not match the published one. Fails closed on purpose — an unreachable or
# incomplete checksums file is a refusal, never a silent unverified install.
verify_binary() {
  local file="$1" name="$2" sums expected actual
  sums=$(curl "${CURL_OPTS[@]}" "${PAGES_BASE}/checksums.txt") \
    || error "Could not fetch ${PAGES_BASE}/checksums.txt. Refusing to install an unverified binary."
  expected=$(checksum_for "${sums}" "${name}")
  [ -n "${expected}" ] || error "No published checksum for ${name}. Refusing to install an unverified binary."
  actual=$(sha256_of "${file}")
  [ "${actual}" = "${expected}" ] || \
    error "Checksum mismatch for ${name}. Expected ${expected}, got ${actual}. Refusing to install."
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
  resolve_endpoints
  preflight
  info "Preflight passed. Site: ${SITE}"
  check_gateway

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
  REGISTER_RESPONSE=$(curl "${CURL_OPTS[@]}" -X POST "${REGISTER_API}" \
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
  TMP_FILES+=("${binary_tmp}")

  mkdir -p "$(dirname "${BINARY_PATH}")"

  curl "${CURL_DOWNLOAD_OPTS[@]}" -o "${binary_tmp}" "${binary_url}" || \
    error "Binary download failed from ${binary_url}. Please try again or contact E2E support."

  info "Verifying the download against the published checksum..."
  verify_binary "${binary_tmp}" "e2e-otel-collector-linux-${ARCH}"

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
  curl "${CURL_OPTS[@]}" -o "${CONFIG_DIR}/config.yaml" "${PAGES_BASE}/samples/vm-config.yaml" || \
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
