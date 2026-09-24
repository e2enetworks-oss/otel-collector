#!/usr/bin/env bash
# E2E Observability Agent — VM installer
# Usage:
#   E2E_PERSONAL_ACCESS_TOKEN=<token> \
#     bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
#
# That installs against production. For a dev stack, set its API origin and
# gateway — see the Endpoints block below:
#   E2E_PERSONAL_ACCESS_TOKEN=<token> E2E_API=http://10.0.0.5:31881 \
#     E2E_INTERNAL_GATEWAY=10.0.0.5:31318 \
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
# E2E_PERSONAL_ACCESS_TOKEN is the only required customer value. The remaining
# settings select a deployment; production has defaults.
#
# E2E_API            API origin that issued the token and mints the ingestion
#                    token. A bare host uses HTTPS. For a NodePort, include the
#                    scheme and port: http://10.0.0.5:31881. No path.
#
# E2E_INTERNAL_GATEWAY
#                    The gateway the agent ships signals to. Hostname, or
#                    host:port when it is not on the default OTLP/gRPC port.
#                    Default: production. Example: 10.0.0.5:31318
#
# The registration URL is always derived from E2E_API and REGISTER_PATH.
DEFAULT_API="api.e2enetworks.com"
DEFAULT_GATEWAY="signals.e2enetworks.net"

# The OTLP/gRPC port assumed when E2E_INTERNAL_GATEWAY names a host with no
# port. 4317 is the OTel standard and the `grpc` port on the gateway Service;
# 31318 is only its NodePort, so a hostname fronting a load balancer lands here.
DEFAULT_GATEWAY_PORT="4317"

# The Signals API creates a collector agent and returns its agent_id here.
REGISTER_PATH="/api/v1/gpu/signals/agents"

# ── Helpers ──────────────────────────────────────────────────────────────────
COLOR_BLUE='' COLOR_GREEN='' COLOR_YELLOW='' COLOR_RED='' COLOR_RESET=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  COLOR_BLUE=$'\033[34m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
  COLOR_RESET=$'\033[0m'
fi

CURRENT_STEP='installation'
step() {
  CURRENT_STEP="$*"
  printf '%b[e2e-install] STEP%b %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}
success() { printf '%b[e2e-install] PASS%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
warn() { printf '%b[e2e-install] WARN%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"; }
error() { printf '%b[e2e-install] FAIL%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; exit 1; }
unexpected_error() {
  local status="$1" line="$2"
  trap - ERR
  printf '%b[e2e-install] FAIL%b %s (line %s, exit %s). Check the command output above.\n' \
    "$COLOR_RED" "$COLOR_RESET" "$CURRENT_STEP" "$line" "$status" >&2
  exit "$status"
}

# Bounds for the small control-plane calls — register, checksums.txt, the
# collector config. Each is a few KB, so a 120s ceiling on the whole request is
# generous, and it catches the half-open route that otherwise hangs an install
# forever with no error. Retries cover a single blip on a customer network.
# No --proto-redir: E2E_API can use HTTP for an internal NodePort deployment.
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

# normalize_gateway <host-or-host:port>: echo host:port, filling in the default
# OTLP/gRPC port when the value names a bare host. Lets E2E_INTERNAL_GATEWAY be
# written the way people say it out loud — "signals.e2enetworks.net".
normalize_gateway() {
  case "$1" in
    *:*) echo "$1" ;;
    *)   echo "$1:${DEFAULT_GATEWAY_PORT}" ;;
  esac
}

# resolve_endpoints: derive the register URL from the API origin and select the
# gateway. E2E_INTERNAL_GATEWAY is the only gateway override.
resolve_endpoints() {
  API_BASE_URL="${E2E_API:-https://${DEFAULT_API}}"
  case "$API_BASE_URL" in
    http://*|https://*) : ;;
    *://*) error "E2E_API must use http:// or https://." ;;
    *) API_BASE_URL="https://${API_BASE_URL}" ;;
  esac
  API_BASE_URL="${API_BASE_URL%/}"
  local authority="${API_BASE_URL#*://}"
  case "$authority" in
    ''|*/*|*\?*|*\#*|*@*) error "E2E_API must be an API origin (scheme, host and optional port), with no path or credentials." ;;
  esac
  REGISTER_URL="${API_BASE_URL}${REGISTER_PATH}"
  INTERNAL_GATEWAY="$(normalize_gateway "${E2E_INTERNAL_GATEWAY:-${DEFAULT_GATEWAY}}")"

  # Whether the gateway is this script's default or somebody's choice decides
  # how hard we check it below: a value an operator typed is their claim to
  # make, a value this script supplied has to prove itself before we ship
  # telemetry at it.
  if [ -n "${E2E_INTERNAL_GATEWAY:-}" ]; then
    GATEWAY_DEFAULTED="no"
  else
    GATEWAY_DEFAULTED="yes"
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
  # Positional arguments are expanded by the child Bash, never parsed as code.
  # shellcheck disable=SC2016
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null
}

# Check the final gateway too: the Signals API may have supplied it after the
# initial preflight, and a URL here would make the collector fail at startup.
validate_gateway() {
  # A scheme on the gateway is the common mistake: it is an OTLP/gRPC dial
  # target, not a URL, and the collector fails obscurely later if one leaks in.
  case "${INTERNAL_GATEWAY}" in
    *://*) error "E2E_INTERNAL_GATEWAY must be host:port with no scheme (got '${INTERNAL_GATEWAY}')." ;;
    *:*)   : ;;
    *)     error "E2E_INTERNAL_GATEWAY must include a port, as host:port (got '${INTERNAL_GATEWAY}')." ;;
  esac
}

# preflight: verify root, required tools, the personal access token, and gateway.
preflight() {
  [ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."
  command -v curl      >/dev/null 2>&1 || error "curl is required but not installed."
  command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || \
    error "Neither sha256sum nor shasum found — the downloaded binary could not be verified."

  [ -n "${E2E_PERSONAL_ACCESS_TOKEN:-}" ] || error "E2E_PERSONAL_ACCESS_TOKEN is not set."
  validate_gateway
}

# check_gateway: an unreachable gateway does not stop the collector — the
# service stays active, retries each batch for five minutes and then drops it,
# so the only symptom is missing data. Refuse to finish an install that would
# land in that state on an endpoint nobody chose. An endpoint the operator
# passed explicitly only warns: their network may open after install.
check_gateway() {
  step "Checking gateway ${INTERNAL_GATEWAY}"
  if gateway_reachable "${INTERNAL_GATEWAY}"; then
    success "Gateway reachable."
    return 0
  fi
  if [ "${GATEWAY_DEFAULTED}" = "yes" ]; then
    error "Cannot reach the default gateway ${INTERNAL_GATEWAY}. This host may be \
outside the E2E internal network, or this deployment may use a different gateway. \
Set E2E_INTERNAL_GATEWAY=<host> (or <host>:<port>) for your environment, then \
re-run. Installing now would collect telemetry and drop it."
  fi
  warn "${INTERNAL_GATEWAY} is not reachable from this host right now. \
Continuing because you set it explicitly — until it opens, the agent collects \
and drops telemetry with no error beyond the service journal."
}

# The API can choose the gateway for this tenant. A nonproduction API must never
# silently fall back to the production gateway when it omits that field.
choose_gateway() {
  local served_gateway="$1"
  if [ -n "${served_gateway}" ] && [ -z "${E2E_INTERNAL_GATEWAY:-}" ]; then
    INTERNAL_GATEWAY="$(normalize_gateway "${served_gateway}")"
    validate_gateway
    GATEWAY_DEFAULTED="no"
    success "Signals API selected gateway ${INTERNAL_GATEWAY}."
  elif [ -z "${served_gateway}" ] && [ -z "${E2E_INTERNAL_GATEWAY:-}" ] && \
       [ "${API_BASE_URL}" != "https://${DEFAULT_API}" ]; then
    error "The Signals API did not return a gateway for ${API_BASE_URL}. Set E2E_INTERNAL_GATEWAY for this deployment."
  fi
}

# telemetry_enabled: install telemetry is OPT-IN. Silence is a no, so a customer
# who never heard of E2E_TELEMETRY never sends anything — which is the only
# reading of consent that survives someone piping this script into a root shell
# without reading it first. Opting out is not a step they have to find.
telemetry_enabled() {
  case "${E2E_TELEMETRY:-}" in
    1|true|yes|on) return 0 ;;
    *)             return 1 ;;
  esac
}

# posthog_capture <event> <properties-json-fragment>: best-effort install
# telemetry. Never fails the install — analytics being down is not an install
# error — and never blocks it for longer than the curl bounds allow.
#
# Two independent gates, both required. E2E_TELEMETRY is the customer's consent;
# E2E_POSTHOG_KEY is the maintainer's. There is no key committed here on purpose:
# PostHog project keys are designed to be public, but which project, which
# region, and whether an install event may carry tenant identifiers are calls
# for the maintainer, not defaults for a script to pick.
posthog_capture() {
  local event="$1" props="$2"
  telemetry_enabled || return 0
  [ -n "${E2E_POSTHOG_KEY:-}" ] || return 0
  local host="${E2E_POSTHOG_HOST:-https://app.posthog.com}"
  curl "${CURL_OPTS[@]}" -X POST "${host}/capture/" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\":\"${E2E_POSTHOG_KEY}\",\"event\":\"${event}\",\
\"distinct_id\":\"${INSTALL_ID}\",\"properties\":{${props}}}" \
    >/dev/null 2>&1 || true
}

# sha256_hex: read stdin, echo its sha256, using whichever tool the distro ships.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# sha256_of <file>: echo the file's sha256.
sha256_of() { sha256_hex < "$1"; }

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
# object. Uses jq when available, falls back to sed otherwise. Echoes the
# value or an empty string when the field is absent.
parse_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r ".${field} // empty"
  else
    # Also accepts normal pretty-printed JSON with spaces around the colon.
    printf '%s\n' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}

# ── Install phases ────────────────────────────────────────────────────────────
detect_platform() {
  step "Detecting platform"
  ARCH=$(detect_arch)
  OS_ID=""
  # shellcheck source=/dev/null
  [ -f /etc/os-release ] && OS_ID=$(. /etc/os-release && echo "${ID:-unknown}")
  success "Platform: linux/${ARCH} (${OS_ID:-unknown distro})"

  # hostname is sent so the server derives a per-host log group
  # (logs.infra.vm.<project_id>.<host>). Sanitized to characters that are
  # safe inside a JSON string; the server re-sanitizes for group naming.
  HOST_NAME=$(hostname -f 2>/dev/null || hostname)
  HOST_NAME=${HOST_NAME//[^a-zA-Z0-9.-]/}

  # Stable per-host pseudonym for install telemetry. Hashed rather than raw so
  # the hostname itself does not leave the network by default; swap it for
  # project_id if attribution to an account is wanted (see posthog_capture).
  INSTALL_ID=$(printf '%s' "${HOST_NAME}" | sha256_hex)
}

register_collector() {
  step "Registering collector with the Signals API (host: ${HOST_NAME})"
  local register_response served_gateway
  # The Signals API still calls this wire field apiKey. Feed it on stdin so
  # the token is absent from curl's process arguments; refuse redirects so the
  # token cannot be forwarded to a different host.
  register_response=$(printf '%s' "{
      \"apiKey\":       \"${E2E_PERSONAL_ACCESS_TOKEN}\",
      \"resourceType\": \"vm\",
      \"hostname\":     \"${HOST_NAME}\"
    }" | curl "${CURL_OPTS[@]}" --max-redirs 0 -X POST "${REGISTER_URL}" \
      -H "Content-Type: application/json" --data-binary @-) || \
    error "Signals API registration failed. Check E2E_PERSONAL_ACCESS_TOKEN and network connectivity."

  E2E_TOKEN=$(parse_field "${register_response}" "ingestion_token")
  E2E_LOG_GROUP=$(parse_field "${register_response}" "log_group")
  E2E_PROJECT_ID=$(parse_field "${register_response}" "project_id")
  E2E_AGENT_ID=$(parse_field "${register_response}" "agent_id")
  # These fields are optional until the Signals API includes them in its reply.
  E2E_CUSTOMER_ID=$(parse_field "${register_response}" "customer_id")
  served_gateway=$(parse_field "${register_response}" "gateway_endpoint")

  [ -n "${E2E_TOKEN:-}"     ] || error "Registration failed: ingestion_token missing. Check your credentials."
  [ -n "${E2E_LOG_GROUP:-}" ] || error "Registration failed: log_group missing. Check your credentials."
  [ -n "${E2E_PROJECT_ID:-}" ] || error "Registration failed: project_id missing. Check your credentials."
  [ -n "${E2E_AGENT_ID:-}" ] || error "Registration failed: agent_id missing from Signals API response."
  success "Signals API registered collector agent ${E2E_AGENT_ID}."

  # An endpoint the API named beats anything this script defaulted to: it knows
  # which gateway serves this tenant, and it is authoritative per environment.
  choose_gateway "${served_gateway}"

  # Checked after registration because the response may name the gateway, and
  # before the download because that is the expensive step worth protecting.
  # Registration is idempotent, so failing here costs nothing but a retry.
  check_gateway
}

install_binary() {
  step "Downloading collector binary (linux/${ARCH})"
  local binary_url="${PAGES_BASE}/e2e-otel-collector-linux-${ARCH}"
  local binary_tmp="${BINARY_PATH}.tmp"
  TMP_FILES+=("${binary_tmp}")

  mkdir -p "$(dirname "${BINARY_PATH}")"

  curl "${CURL_DOWNLOAD_OPTS[@]}" -o "${binary_tmp}" "${binary_url}" || \
    error "Binary download failed from ${binary_url}. Please try again or contact E2E support."

  step "Verifying collector checksum"
  verify_binary "${binary_tmp}" "e2e-otel-collector-linux-${ARCH}"

  chmod +x "${binary_tmp}"
  mv "${binary_tmp}" "${BINARY_PATH}"
  success "Verified binary installed at ${BINARY_PATH}"
}

write_configuration() {
  step "Writing collector configuration"
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/tmp"
  chmod 755 "${CONFIG_DIR}"
  chmod 700 "${DATA_DIR}"

  # Env file (mode 600 — credentials). HOST_NAME was computed and
  # sanitized before registration so both use the same value.
  cat > "${CONFIG_DIR}/env" <<EOF
E2E_TOKEN=${E2E_TOKEN}
HOST_NAME=${HOST_NAME}
E2E_LOG_GROUP=${E2E_LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
E2E_AGENT_ID=${E2E_AGENT_ID}
E2E_CUSTOMER_ID=${E2E_CUSTOMER_ID}
E2E_INTERNAL_GATEWAY=${INTERNAL_GATEWAY}
EOF
  chmod 600 "${CONFIG_DIR}/env"

  # Collector config (fetched from GitHub Pages)
  curl "${CURL_OPTS[@]}" -o "${CONFIG_DIR}/config.yaml" "${PAGES_BASE}/samples/vm-config.yaml" || \
    error "Failed to download vm-config.yaml from ${PAGES_BASE}/samples/vm-config.yaml."
  chmod 644 "${CONFIG_DIR}/config.yaml"
  success "Collector configuration written to ${CONFIG_DIR}"
}

install_service() {
  step "Installing and starting systemd service"
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
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    systemctl restart "${SERVICE_NAME}"
  else
    systemctl start "${SERVICE_NAME}"
  fi
  systemctl is-active --quiet "${SERVICE_NAME}" || \
    error "${SERVICE_NAME} is not active. Check journalctl -u ${SERVICE_NAME} -n 100."
  success "${SERVICE_NAME} is active."
}

finish_install() {
  # Install telemetry. Last, so it reports only installs that actually finished,
  # and best-effort, so it can never be the reason one fails.
  posthog_capture "vm_agent_installed" \
    "\"arch\":\"${ARCH}\",\"distro\":\"${OS_ID:-unknown}\",\
\"api_host\":\"${API_BASE_URL}\",\"gateway\":\"${INTERNAL_GATEWAY}\",\
\"collector_binary\":\"e2e-otel-collector-linux-${ARCH}\""

  # Done
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " E2E Observability Agent installed; service is active."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Host:      ${HOST_NAME}"
  echo " Agent ID:  ${E2E_AGENT_ID}"
  echo " Log group: ${E2E_LOG_GROUP}"
  echo " Project:   ${E2E_PROJECT_ID}"
  echo ""
  echo " Status:    systemctl status ${SERVICE_NAME}"
  echo " Logs:      journalctl -u ${SERVICE_NAME} -f"
  echo " Health:    curl -s http://localhost:13133"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
  set -E
  trap 'unexpected_error "$?" "$LINENO"' ERR

  step "Checking requirements"
  resolve_endpoints
  preflight
  success "Requirements passed. API: ${API_BASE_URL}"

  detect_platform
  register_collector
  install_binary
  write_configuration
  install_service
  finish_install
}

# Run main only when executed directly — not when sourced by tests (bats).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
