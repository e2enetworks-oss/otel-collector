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

# ── parse_field (grep/cut path — hide jq from PATH) ──────────────────────────

@test "parse_field extracts ingestion_token without jq" {
  # parse_field probes for jq via `command -v jq`; shadowing the `command`
  # builtin with a function that reports jq absent forces the grep/cut path.
  run bash -c '
    source "'"${REPO_ROOT}"'/install.sh"
    command() { if [ "$2" = "jq" ]; then return 1; fi; builtin command "$@"; }
    parse_field "{\"ingestion_token\":\"sk_abc123\",\"log_group\":\"logs.vm.1\"}" "ingestion_token"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sk_abc123" ]
}

@test "parse_field returns empty for missing field (grep path)" {
  run bash -c '
    source "'"${REPO_ROOT}"'/install.sh"
    command() { if [ "$2" = "jq" ]; then return 1; fi; builtin command "$@"; }
    parse_field "{\"log_group\":\"logs.vm.1\"}" "ingestion_token"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "preflight fails when E2E_API_KEY is missing" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  unset E2E_API_KEY
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_API_KEY is not set"* ]]
}

# preflight reads the resolved globals, which resolve_endpoints fills. The
# customer path — API key and nothing else — is the case that regressed once
# already, so it is asserted end to end from an empty environment.
@test "preflight passes with only E2E_API_KEY set" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_API_KEY=key
  unset E2E_API E2E_INTERNAL_GATEWAY E2E_REGISTER_API E2E_GATEWAY_ENDPOINT
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
  export E2E_API_KEY=key
  GATEWAY_ENDPOINT="https://gw.example:31318"
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
  export E2E_API_KEY=key
  GATEWAY_ENDPOINT="gw.example"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"must include a port"* ]]
}

# ── resolve_endpoints ────────────────────────────────────────────────────────
# Called directly, never through `run`: it sets globals, and `run` would
# evaluate it in a subshell where those assignments are thrown away.

clear_endpoint_env() { unset E2E_API E2E_INTERNAL_GATEWAY E2E_REGISTER_API E2E_GATEWAY_ENDPOINT; }

@test "resolve_endpoints falls back to production with nothing set" {
  clear_endpoint_env
  resolve_endpoints
  [ "$API_HOST" = "api.e2enetworks.com" ]
  [ "$REGISTER_API" = "https://api.e2enetworks.com/v1/install/register" ]
  [ "$GATEWAY_ENDPOINT" = "signals.e2enetworks.net:4317" ]
  [ "$GATEWAY_DEFAULTED" = "yes" ]
}

@test "resolve_endpoints builds the register URL from E2E_API" {
  clear_endpoint_env
  export E2E_API="api-groot.e2enetworks.net"
  resolve_endpoints
  [ "$REGISTER_API" = "https://api-groot.e2enetworks.net/v1/install/register" ]
  # E2E_API selects the API only. The gateway has its own variable.
  [ "$GATEWAY_ENDPOINT" = "signals.e2enetworks.net:4317" ]
}

@test "resolve_endpoints lets E2E_REGISTER_API win over the derived URL" {
  clear_endpoint_env
  export E2E_API="api-groot.e2enetworks.net"
  export E2E_REGISTER_API="http://10.0.0.5:31881/v1/install/register"
  resolve_endpoints
  [ "$REGISTER_API" = "http://10.0.0.5:31881/v1/install/register" ]
}

@test "resolve_endpoints takes the gateway from E2E_INTERNAL_GATEWAY" {
  clear_endpoint_env
  export E2E_INTERNAL_GATEWAY="10.0.0.5:31318"
  resolve_endpoints
  [ "$GATEWAY_ENDPOINT" = "10.0.0.5:31318" ]
  # Drives check_gateway: a defaulted endpoint is fatal, a chosen one warns.
  [ "$GATEWAY_DEFAULTED" = "no" ]
}

@test "resolve_endpoints lets E2E_GATEWAY_ENDPOINT win over E2E_INTERNAL_GATEWAY" {
  clear_endpoint_env
  export E2E_INTERNAL_GATEWAY="from-internal.example"
  export E2E_GATEWAY_ENDPOINT="from-endpoint.example:31318"
  resolve_endpoints
  [ "$GATEWAY_ENDPOINT" = "from-endpoint.example:31318" ]
  [ "$GATEWAY_DEFAULTED" = "no" ]
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

# ── posthog_capture ──────────────────────────────────────────────────────────

# A curl stub that leaves a marker file. posthog_capture redirects curl's stdout
# and stderr to /dev/null, so anything the stub PRINTS is invisible to the test —
# the marker is the only reliable evidence that the network was reached.
CURL_MARKER=""
loud_curl() {
  CURL_MARKER="${STUB_DIR}/curl-was-called"
  stub curl <<EOF
#!/usr/bin/env bash
touch "${CURL_MARKER}"
exit 1
EOF
}

@test "posthog_capture is a no-op when no key is configured" {
  export E2E_TELEMETRY=1
  unset E2E_POSTHOG_KEY
  loud_curl
  run posthog_capture "vm_agent_installed" '"arch":"amd64"'
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_MARKER" ]
}

@test "posthog_capture sends nothing without opt-in, even with a key set" {
  # The default. A customer who never set E2E_TELEMETRY sends nothing, whatever
  # key the published script happens to ship with.
  unset E2E_TELEMETRY
  export E2E_POSTHOG_KEY="phc_test"
  loud_curl
  run posthog_capture "vm_agent_installed" '"arch":"amd64"'
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_MARKER" ]
}

@test "telemetry_enabled accepts only affirmative opt-in values" {
  for v in 1 true yes on; do
    E2E_TELEMETRY="$v" telemetry_enabled || { echo "rejected affirmative: $v"; return 1; }
  done
  for v in "" 0 false no off maybe TRUE; do
    if E2E_TELEMETRY="$v" telemetry_enabled; then echo "accepted non-affirmative: $v"; return 1; fi
  done
}

@test "posthog_capture never fails the install when the endpoint is down" {
  export E2E_TELEMETRY=1
  export E2E_POSTHOG_KEY="phc_test"
  export E2E_POSTHOG_HOST="http://127.0.0.1:1"
  INSTALL_ID="deadbeef"
  run posthog_capture "vm_agent_installed" '"arch":"amd64"'
  [ "$status" -eq 0 ]
}

# ── gateway_reachable ────────────────────────────────────────────────────────

@test "gateway_reachable reports reachable when timeout is unavailable" {
  # Not being able to run the check is not evidence of an unreachable gateway,
  # so it must not fail an install on a host without coreutils' timeout.
  run bash -c '
    source "'"${REPO_ROOT}"'/install.sh"
    command() { if [ "$2" = "timeout" ]; then return 1; fi; builtin command "$@"; }
    gateway_reachable "gw.example:31318"
  '
  [ "$status" -eq 0 ]
}

@test "gateway_reachable fails on a closed port" {
  # Port 1 on the loopback interface: nothing listens, and the connection is
  # refused immediately rather than hanging until the 5s timeout.
  run gateway_reachable "127.0.0.1:1"
  [ "$status" -ne 0 ]
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
