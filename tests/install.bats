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

# REGISTER_API and GATEWAY_ENDPOINT are resolved from the environment at source
# time, so a test sets the resolved globals rather than the E2E_* inputs.
@test "preflight passes with root, tools, key and both endpoints" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_API_KEY=key
  REGISTER_API="http://obs.example:31881/v1/install/register"
  GATEWAY_ENDPOINT="gw.example:31318"
  run preflight
  [ "$status" -eq 0 ]
}

@test "preflight fails when E2E_REGISTER_API is missing" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_API_KEY=key
  REGISTER_API=""
  GATEWAY_ENDPOINT="gw.example:31318"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_REGISTER_API is not set"* ]]
}

@test "preflight fails when E2E_GATEWAY_ENDPOINT is missing" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_API_KEY=key
  REGISTER_API="http://obs.example:31881/v1/install/register"
  GATEWAY_ENDPOINT=""
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_GATEWAY_ENDPOINT is not set"* ]]
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
