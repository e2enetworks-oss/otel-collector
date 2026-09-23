#!/usr/bin/env bash
# E2E Observability Agent — VM installer
#
# Two provisioning modes:
#
#  1. TIR-PROVISIONED (what the "start observability" button uses).
#     The TIR backend has already called /v1/install/register on the customer's
#     behalf — it resolves the project from the API token the customer presented,
#     mints the ingestion token, and embeds both in the command:
#
#       E2E_TOKEN=<token> E2E_PROJECT_ID=<project> E2E_LOG_GROUP=<group> \
#       E2E_GATEWAY_ENDPOINT=<gateway-host>:31318 \
#         bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
#
#     Nothing is minted here and no API key ever reaches this host.
#
#  2. SELF-REGISTRATION (manual / legacy). This script calls the register API
#     itself with an API key:
#
#       E2E_API_KEY=<key> \
#       E2E_REGISTER_API=http://<obs-api-host>:31881/v1/install/register \
#       E2E_GATEWAY_ENDPOINT=<gateway-host>:31318 \
#         bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
#
# Either way the collector ends up holding an ingestion token, and THAT is what
# carries tenancy: the gateway resolves the owning project from the token and
# stamps it onto every span, metric and log, overwriting anything this host
# claims about itself. A tampered E2E_PROJECT_ID here cannot move data into
# another tenant.

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
#
# Override with E2E_PAGES_BASE to install from an unpublished tree: a local
# HTTP server, or a file:// path to a directory already copied onto this host.
# Needed whenever the config has changed but has not been released yet —
# otherwise this pulls the last PUBLISHED samples/vm-config.yaml, which silently
# reinstates a hardcoded gateway and drops the env-driven settings below.
PAGES_BASE="${E2E_PAGES_BASE:-https://e2enetworks-oss.github.io/otel-collector}"

# The collector config specifically. Split from PAGES_BASE so the config can be
# overridden on its own — the common case is testing an updated config against
# the stock released binary, which needs no override.
CONFIG_URL="${E2E_CONFIG_URL:-${PAGES_BASE}/samples/vm-config.yaml}"

# ── Endpoints ────────────────────────────────────────────────────────────────
# Both are deployment-specific and have NO DEFAULT — set them for your
# environment, or pass them as env vars at install time. A default here was
# previously 172.16.230.168:31318, an RFC1918 address that silently pointed
# every external install at a gateway it cannot route to.
#
# E2E_REGISTER_API   The observability-api REST service. Serves
#                    POST /v1/install/register, which exchanges the API key for
#                    an ingestion token, project_id, and log_group.
#                    Required ONLY in self-registration mode — the TIR flow
#                    never calls it, because TIR already registered.
#                    Example: http://<obs-api-host>:31881/v1/install/register
#
# E2E_GATEWAY_ENDPOINT
#                    The otel-gateway OTLP/gRPC listener that the agent ships
#                    telemetry to. Host:port only — no scheme, no path.
#                    Required in BOTH modes.
#                    Example: <gateway-host>:31318
REGISTER_API="${E2E_REGISTER_API:-}"
GATEWAY_ENDPOINT="${E2E_GATEWAY_ENDPOINT:-}"

# E2E_GATEWAY_INSECURE=true sends the ingestion token in CLEARTEXT. That is only
# defensible inside E2E's private network. Any install reachable over the public
# internet MUST pass false, or the token can be lifted in transit and used to
# impersonate the tenant.
GATEWAY_INSECURE="${E2E_GATEWAY_INSECURE:-true}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-install] $*"; }
error() { echo "[e2e-install] ERROR: $*" >&2; exit 1; }

# ── Pure functions (unit-testable via bats) ──────────────────────────────────

# preflight: verify root, required tools, and required env vars.
#
# Order matters. Credentials and endpoints are validated BEFORE the gateway is
# inspected: with no default for GATEWAY_ENDPOINT, an unset value would other-
# wise fall through the address check below and print "looks public but TLS is
# disabled" about an empty string, burying the real cause.
preflight() {
  [ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo or run as root)."

  command -v curl      >/dev/null 2>&1 || error "curl is required but not installed."
  command -v systemctl >/dev/null 2>&1 || error "systemctl not found — this installer requires a systemd-based OS."

  # TIR-provisioned mode is detected by E2E_TOKEN being present. It must arrive
  # complete: a token without its project/log group would install an agent that
  # ships data it cannot attribute.
  if [ -n "${E2E_TOKEN:-}" ]; then
    [ -n "${E2E_PROJECT_ID:-}" ] || \
      error "E2E_TOKEN was supplied without E2E_PROJECT_ID — the install command is incomplete."
    [ -n "${E2E_LOG_GROUP:-}" ] || \
      error "E2E_TOKEN was supplied without E2E_LOG_GROUP — the install command is incomplete."
  else
    [ -n "${E2E_API_KEY:-}" ] || \
      error "Neither E2E_TOKEN (TIR-provisioned) nor E2E_API_KEY (self-registration) is set."
    # Only this mode calls the register API, so only this mode needs its address.
    # Requiring it unconditionally would break every TIR-provisioned install,
    # which never contacts the endpoint at all.
    [ -n "${REGISTER_API:-}" ] || error \
      "E2E_REGISTER_API is not set. Point it at the observability-api register endpoint, e.g. http://<obs-api-host>:31881/v1/install/register"
  fi

  # Needed in both modes: it is where the collector ships everything.
  [ -n "${GATEWAY_ENDPOINT:-}" ] || error \
    "E2E_GATEWAY_ENDPOINT is not set. Point it at the otel-gateway OTLP/gRPC listener as host:port, e.g. <gateway-host>:31318"

  # A private gateway address cannot be reached from outside E2E's network, and
  # cleartext transport cannot protect a token that crosses it. Flag both rather
  # than letting an external install fail silently or leak.
  case "${GATEWAY_ENDPOINT}" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|localhost*|127.*)
      if [ "${GATEWAY_INSECURE}" != "true" ]; then
        info "NOTE: gateway ${GATEWAY_ENDPOINT} is a private address with TLS enabled."
      fi
      ;;
    *)
      [ "${GATEWAY_INSECURE}" = "true" ] && \
        info "WARNING: gateway ${GATEWAY_ENDPOINT} looks public but TLS is disabled — the ingestion token will cross the network in cleartext."
      ;;
  esac
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

  # Computed before either branch: the env file below writes it as HOST_NAME in
  # both modes, and self-registration additionally sends it so the server
  # derives a per-host log group (logs.infra.vm.<project_id>.<host>). Sanitized
  # to characters safe inside a JSON string; the server re-sanitizes for naming.
  local host_name
  host_name=$(hostname -f 2>/dev/null || hostname)
  host_name=${host_name//[^a-zA-Z0-9.-]/}

  # Phase 2: Obtain the ingestion token.
  #
  # Skipped entirely when TIR already provisioned one — that is the normal path
  # for the "start observability" button, and it means no API key is present on
  # this host to be read out of the process table or a shell history file.
  if [ -n "${E2E_TOKEN:-}" ]; then
    info "Using credentials provisioned by TIR (project ${E2E_PROJECT_ID}); skipping registration."
  else
    info "Registering with E2E Observability API (host: ${host_name})..."
    # NOTE: the register endpoint's RegisterRequest uses
    # #[serde(rename_all = "camelCase")] — field names must be apiKey /
    # resourceType, not api_key / resource_type, or the server returns a 422.
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
  fi

  # Phase 3: Download binary
  info "Downloading E2E OTel Collector binary (linux/${ARCH})..."
  local binary_url="${PAGES_BASE}/e2e-otel-collector-linux-${ARCH}"
  local binary_tmp="${BINARY_PATH}.tmp"

  mkdir -p "$(dirname "${BINARY_PATH}")"

  curl -fsSL --progress-bar -o "${binary_tmp}" "${binary_url}" || \
    error "Binary download failed from ${binary_url}. Please try again or contact E2E support."

  chmod +x "${binary_tmp}"

  # Verify BEFORE moving it into place. A truncated or wrong-architecture
  # download still arrives with a 200 and still chmods fine — the failure only
  # shows up later as a systemd restart loop, which is a much harder thing for a
  # customer to diagnose than an install that refuses to finish.
  #
  # The temp file is left behind deliberately on failure: it is the evidence.
  # `components` lists the collector's compiled-in component registry. It is the
  # cheapest call that actually exercises the binary, and unlike `--version` it
  # exists: this collector is built with the OTel Collector Builder, whose
  # distributions expose no --version flag at all, so probing for one aborted
  # every install with a message blaming the architecture.
  if ! "${binary_tmp}" components >/dev/null 2>&1; then
    error "Downloaded binary did not run (wrong architecture, truncated download, or unsupported kernel). Left at ${binary_tmp} for inspection."
  fi

  mv "${binary_tmp}" "${BINARY_PATH}"

  # Re-verify from the final path, so a failed move or a clobbered destination
  # cannot be mistaken for a working install.
  "${BINARY_PATH}" components >/dev/null 2>&1 || \
    error "Binary at ${BINARY_PATH} is not executable after install."

  info "Binary installed and verified at ${BINARY_PATH}"

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
E2E_GATEWAY_INSECURE=${GATEWAY_INSECURE}
EOF
  chmod 600 "${CONFIG_DIR}/env"

  # 4b. Collector config (from CONFIG_URL — Pages unless overridden)
  info "Fetching collector config from ${CONFIG_URL}..."
  curl -fsSL -o "${CONFIG_DIR}/config.yaml" "${CONFIG_URL}" || \
    error "Failed to download collector config from ${CONFIG_URL}."
  chmod 644 "${CONFIG_DIR}/config.yaml"

  # A config that predates the env-driven gateway would leave the collector
  # pointing at whatever address was baked in at release time, while the env
  # file below advertises the one TIR actually sent. That mismatch produces a
  # collector that starts cleanly and ships to the wrong place, so fail here
  # instead.
  for marker in 'env:E2E_GATEWAY_ENDPOINT' 'env:E2E_GATEWAY_INSECURE' 'otlp/local'; do
    grep -q "${marker}" "${CONFIG_DIR}/config.yaml" || \
      error "Collector config at ${CONFIG_URL} is out of date (missing ${marker}). Point E2E_CONFIG_URL at an updated config."
  done

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
  echo " Gateway:   ${GATEWAY_ENDPOINT} (tls insecure: ${GATEWAY_INSECURE})"
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
