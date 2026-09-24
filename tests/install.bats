#!/usr/bin/env bats
# Unit tests for install.sh pure functions.
# Run with: bats tests/
#
# install.sh guards its main() behind a BASH_SOURCE check, so sourcing it here
# loads the functions without running the installer.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Stub directory takes precedence on PATH so tests control `uname`, `jq`, etc.
  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"

  # install.sh runs `set -euo pipefail` at top level. Disable errexit for the
  # source (otherwise the first non-zero command aborts it), then restore it.
  #
  # RESTORING errexit is load-bearing: bats fails a test when a command in it
  # returns non-zero, which it can only see while errexit is on. Leaving it off
  # made every assertion in this file advisory — `[ 1 -eq 2 ]` reported ok, and
  # so did a preflight test asserting success on a preflight that exits 1.
  # nounset and pipefail stay off so a bare $VAR reference does not fail oddly.
  set +e
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/install.sh"
  set -e
  set +u +o pipefail
  JQ_BIN=$(command -v jq)
}

teardown() {
  rm -rf "${STUB_DIR}"
}

# Helper: create an executable stub on PATH.
stub() {
  local name="$1"; shift
  cat > "${STUB_DIR}/${name}"
  chmod +x "${STUB_DIR}/${name}"
}

# ── detect_arch ───────────────────────────────────────────────────────────────

@test "detect_arch maps x86_64 to amd64" {
  stub uname <<'EOF'
#!/usr/bin/env bash
echo "x86_64"
EOF
  run detect_arch
  [ "$status" -eq 0 ]
  [ "$output" = "amd64" ]
}

@test "detect_arch maps aarch64 to arm64" {
  stub uname <<'EOF'
#!/usr/bin/env bash
echo "aarch64"
EOF
  run detect_arch
  [ "$status" -eq 0 ]
  [ "$output" = "arm64" ]
}

@test "detect_arch rejects unsupported architecture" {
  stub uname <<'EOF'
#!/usr/bin/env bash
echo "i686"
EOF
  run detect_arch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported architecture: i686"* ]]
}

# ── parse_field ───────────────────────────────────────────────────────────────

@test "parse_field extracts a top-level string" {
  run parse_field '{"ingestion_token":"sk_abc123","nested":{"ingestion_token":"wrong"}}' "ingestion_token"
  [ "$status" -eq 0 ]
  [ "$output" = "sk_abc123" ]
}

@test "parse_field decodes escaped JSON characters" {
  run parse_field '{"agent_id" : "agent-\"123"}' "agent_id"
  [ "$status" -eq 0 ]
  [ "$output" = 'agent-"123' ]
}

@test "parse_field returns empty for missing field" {
  run parse_field '{"log_group":"logs.vm.1"}' "ingestion_token"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parse_field rejects malformed JSON" {
  run parse_field '{"agent_id":' "agent_id"
  [ "$status" -ne 0 ]
}

@test "registration_json escapes the personal access token" {
  export E2E_PERSONAL_ACCESS_TOKEN='pat-"test'
  HOST_NAME="web-01"
  run registration_json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .apiKey)" = "$E2E_PERSONAL_ACCESS_TOKEN" ]
}

@test "ensure_jq reuses an installed parser" {
  JQ_BIN=""
  ensure_jq
  [ -x "$JQ_BIN" ]
}

@test "validate_env_value rejects a newline from the API" {
  run validate_env_value "agent_id" $'agent-123\nE2E_TOKEN=other'
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent_id contains unsupported characters"* ]]
}

@test "register_collector names the agent_id returned by the Signals API" {
  export E2E_PERSONAL_ACCESS_TOKEN='pat-"test'
  export E2E_INTERNAL_GATEWAY="gw.example:4317"
  unset E2E_API
  resolve_endpoints
  HOST_NAME="web-01"
stub curl <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'pat-"test'*) exit 9 ;;
esac
request=$(cat)
printf '%s' "$request" | jq -e '.apiKey == "pat-\"test" and .resourceType == "vm" and .hostname == "web-01"' >/dev/null || exit 9
printf '{"agent_id":"agent-123","ingestion_token":"ingest-123","project_id":"project-123","log_group":"logs.web-01"}'
EOF
  gateway_reachable() { return 0; }
  register_collector
  [ "$E2E_AGENT_ID" = "agent-123" ]
  [ "$E2E_TOKEN" = "ingest-123" ]
}

@test "register_collector fails when the Signals API omits agent_id" {
  export E2E_PERSONAL_ACCESS_TOKEN="pat-test"
  export E2E_INTERNAL_GATEWAY="gw.example:4317"
  unset E2E_API
  resolve_endpoints
  HOST_NAME="web-01"
  stub curl <<'EOF'
#!/usr/bin/env bash
printf '{"ingestion_token":"ingest-123","project_id":"project-123","log_group":"logs.web-01"}'
EOF
  gateway_reachable() { return 0; }
  run register_collector
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL Registration failed: agent_id missing"* ]]
}

# ── preflight ─────────────────────────────────────────────────────────────────

@test "preflight fails when not root" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "1000"
EOF
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "preflight fails when E2E_PERSONAL_ACCESS_TOKEN is missing" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  unset E2E_PERSONAL_ACCESS_TOKEN
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_PERSONAL_ACCESS_TOKEN is not set"* ]]
}

# preflight reads the resolved globals, which resolve_endpoints fills. The
# customer path — personal access token and nothing else — once regressed, so
# it is asserted from an empty endpoint environment.
@test "preflight passes with only E2E_PERSONAL_ACCESS_TOKEN set" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_PERSONAL_ACCESS_TOKEN=token
  unset E2E_API E2E_INTERNAL_GATEWAY
  resolve_endpoints
  run preflight
  [ "$status" -eq 0 ]
}

@test "preflight rejects a gateway carrying a scheme" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_PERSONAL_ACCESS_TOKEN=token
  INTERNAL_GATEWAY="https://gw.example:31318"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"no scheme"* ]]
}

@test "preflight rejects a gateway with no port" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_PERSONAL_ACCESS_TOKEN=token
  INTERNAL_GATEWAY="gw.example"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"must include a port"* ]]
}

# ── resolve_endpoints ────────────────────────────────────────────────────────
# Called directly, never through `run`: it sets globals, and `run` would
# evaluate it in a subshell where those assignments are thrown away.

clear_endpoint_env() { unset E2E_API E2E_INTERNAL_GATEWAY; }

@test "resolve_endpoints falls back to production with nothing set" {
  clear_endpoint_env
  resolve_endpoints
  [ "$API_BASE_URL" = "https://api.e2enetworks.com" ]
  [ "$REGISTER_URL" = "https://api.e2enetworks.com/api/v1/gpu/signals/agents" ]
  [ "$INTERNAL_GATEWAY" = "signals.e2enetworks.net:4317" ]
  [ "$GATEWAY_DEFAULTED" = "yes" ]
}

@test "resolve_endpoints builds the register URL from E2E_API" {
  clear_endpoint_env
  export E2E_API="api-groot.e2enetworks.net"
  resolve_endpoints
  [ "$REGISTER_URL" = "https://api-groot.e2enetworks.net/api/v1/gpu/signals/agents" ]
  # E2E_API selects the API only. The gateway has its own variable.
  [ "$INTERNAL_GATEWAY" = "signals.e2enetworks.net:4317" ]
}

@test "resolve_endpoints derives a NodePort registration URL from E2E_API" {
  clear_endpoint_env
  export E2E_API="http://10.0.0.5:31881/"
  resolve_endpoints
  [ "$API_BASE_URL" = "http://10.0.0.5:31881" ]
  [ "$REGISTER_URL" = "http://10.0.0.5:31881/api/v1/gpu/signals/agents" ]
}

@test "resolve_endpoints takes the gateway from E2E_INTERNAL_GATEWAY" {
  clear_endpoint_env
  export E2E_INTERNAL_GATEWAY="10.0.0.5:31318"
  resolve_endpoints
  [ "$INTERNAL_GATEWAY" = "10.0.0.5:31318" ]
  # Drives check_gateway: a defaulted endpoint is fatal, a chosen one warns.
  [ "$GATEWAY_DEFAULTED" = "no" ]
}

@test "choose_gateway refuses to pair a dev API with the production gateway" {
  clear_endpoint_env
  export E2E_API="https://dev.example"
  resolve_endpoints
  run choose_gateway ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Set E2E_INTERNAL_GATEWAY"* ]]
}

@test "choose_gateway accepts a gateway returned by the Signals API" {
  clear_endpoint_env
  export E2E_API="https://dev.example"
  resolve_endpoints
  choose_gateway "gw.dev.example"
  [ "$INTERNAL_GATEWAY" = "gw.dev.example:4317" ]
  [ "$GATEWAY_DEFAULTED" = "no" ]
}

@test "choose_gateway rejects a URL returned by the Signals API" {
  clear_endpoint_env
  export E2E_API="https://dev.example"
  resolve_endpoints
  run choose_gateway "https://gw.dev.example:4317"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be host:port with no scheme"* ]]
}

@test "validate_gateway rejects a nonnumeric port" {
  INTERNAL_GATEWAY="gw.example:abc"
  run validate_gateway
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric port"* ]]
}

@test "choose_gateway preserves an explicitly selected gateway" {
  clear_endpoint_env
  export E2E_API="https://dev.example"
  export E2E_INTERNAL_GATEWAY="my-gateway.example:31318"
  resolve_endpoints
  choose_gateway "gw.from.api.example"
  [ "$INTERNAL_GATEWAY" = "my-gateway.example:31318" ]
  [ "$GATEWAY_DEFAULTED" = "no" ]
}

@test "status messages identify success and failure without color when piped" {
  run success "Service is active"
  [ "$status" -eq 0 ]
  [ "$output" = "[e2e-install] PASS Service is active" ]
  run error "Service failed"
  [ "$status" -eq 1 ]
  [ "$output" = "[e2e-install] FAIL Service failed" ]
}

# ── normalize_gateway ────────────────────────────────────────────────────────

@test "normalize_gateway appends the default OTLP port to a bare host" {
  run normalize_gateway "signals.e2enetworks.net"
  [ "$status" -eq 0 ]
  [ "$output" = "signals.e2enetworks.net:4317" ]
}

@test "normalize_gateway leaves an explicit port alone" {
  run normalize_gateway "10.0.0.5:31318"
  [ "$status" -eq 0 ]
  [ "$output" = "10.0.0.5:31318" ]
}

# ── gateway_reachable ────────────────────────────────────────────────────────

@test "gateway_reachable reports that the check is unavailable without timeout" {
  run bash -c '
    source "'"${REPO_ROOT}"'/install.sh"
    command() { if [ "$2" = "timeout" ]; then return 1; fi; builtin command "$@"; }
    gateway_reachable "gw.example:31318"
  '
  [ "$status" -eq 2 ]
}

@test "check_gateway warns when it cannot check reachability" {
  INTERNAL_GATEWAY="gw.example:4317"
  GATEWAY_DEFAULTED="yes"
  gateway_reachable() { return 2; }
  run check_gateway
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN Could not check gateway reachability"* ]]
}

@test "gateway_reachable fails on a closed port" {
  # Port 1 on the loopback interface: nothing listens, and the connection is
  # refused immediately rather than hanging until the 5s timeout.
  run gateway_reachable "127.0.0.1:1"
  [ "$status" -ne 0 ]
}

@test "gateway_reachable does not execute a gateway value as shell code" {
  timeout() { shift; "$@"; }
  local marker="${STUB_DIR}/gateway-command-ran"
  gateway_reachable "127.0.0.1:1; touch ${marker}" || true
  [ ! -e "$marker" ]
}

# ── checksum verification ────────────────────────────────────────────────────

@test "checksum_for finds the digest for the requested file" {
  sums="aaa111  e2e-otel-collector-linux-amd64
bbb222  e2e-otel-collector-linux-arm64"
  run checksum_for "$sums" "e2e-otel-collector-linux-arm64"
  [ "$status" -eq 0 ]
  [ "$output" = "bbb222" ]
}

@test "checksum_for returns nothing for a file that is not listed" {
  sums="aaa111  e2e-otel-collector-linux-amd64"
  run checksum_for "$sums" "e2e-otel-collector-windows-amd64.exe"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "checksum_for does not match on a partial filename" {
  sums="aaa111  e2e-otel-collector-linux-amd64"
  run checksum_for "$sums" "linux-amd64"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sha256_of computes a known digest" {
  tmpf="$(mktemp)"
  printf 'e2e' > "$tmpf"
  run sha256_of "$tmpf"
  rm -f "$tmpf"
  [ "$status" -eq 0 ]
  # Hardcoded, not recomputed with shasum: the assertion must not depend on the
  # same tool family the function under test picks.
  [ "$output" = "6d8749c4fe00b757c1bc1c376a99f31d1bd38b422d44f5b6aa2d6a6c5e975cba" ]
}

@test "the suite can actually fail — guards the errexit restore in setup" {
  run bash -c 'exit 3'
  [ "$status" -eq 3 ]
}
