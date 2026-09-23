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
  # source (otherwise the first non-zero command aborts it), then clear nounset
  # and pipefail afterward — they would otherwise leak into every test and make
  # a future bare-$VAR reference fail confusingly.
  set +e
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/install.sh"
  set +u +o pipefail

  # errexit MUST go back on. bats decides pass/fail from the test body aborting
  # on a non-zero command, so leaving it off makes every `[ ... ]` assertion
  # advisory: the suite then reports "ok" for a test asserting `[ 1 -eq 2 ]`,
  # and for a preflight that actually errored. Failures via `run` still work —
  # `run` captures the status instead of letting it abort.
  set -e
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

# root + tooling stubs shared by every preflight credential case.
stub_root_env() {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # curl must be stubbed too: preflight checks for it before it looks at any
  # credential, and the bats image ships neither curl nor systemctl. Without
  # this every credential case died on "curl is required" and never reached the
  # branch it meant to exercise.
  stub curl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  unset E2E_API_KEY E2E_TOKEN E2E_PROJECT_ID E2E_LOG_GROUP

  # GATEWAY_ENDPOINT is now required in both modes and has no default. Set the
  # resolved variable, not E2E_GATEWAY_ENDPOINT: setup() already sourced
  # install.sh, so the `${E2E_GATEWAY_ENDPOINT:-}` assignment has long since run.
  GATEWAY_ENDPOINT="gateway.example:31318"
  GATEWAY_INSECURE="true"
  REGISTER_API="http://obs.example:31881/v1/install/register"
}

@test "preflight fails when no credentials at all are supplied" {
  stub_root_env
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"Neither E2E_TOKEN"* ]]
}

# ── TIR-provisioned mode ──────────────────────────────────────────────────────
#
# The "start observability" button embeds a token minted by the TIR backend.
# It must arrive COMPLETE: a token without its project or log group installs an
# agent that ships data it cannot attribute.

@test "preflight passes with a complete TIR-provisioned credential set" {
  stub_root_env
  export E2E_TOKEN=tok E2E_PROJECT_ID=1550 E2E_LOG_GROUP=logs.infra.vm.1550
  run preflight
  [ "$status" -eq 0 ]
}

@test "preflight needs no API key when TIR provisioned the token" {
  # The whole point of the TIR path: no API key ever reaches the host.
  stub_root_env
  export E2E_TOKEN=tok E2E_PROJECT_ID=1550 E2E_LOG_GROUP=logs.infra.vm.1550
  run preflight
  [ "$status" -eq 0 ]
  [ -z "${E2E_API_KEY:-}" ]
}

@test "preflight fails when TIR token arrives without a project" {
  stub_root_env
  export E2E_TOKEN=tok E2E_LOG_GROUP=logs.infra.vm.1550
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"without E2E_PROJECT_ID"* ]]
}

@test "preflight fails when TIR token arrives without a log group" {
  stub_root_env
  export E2E_TOKEN=tok E2E_PROJECT_ID=1550
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"without E2E_LOG_GROUP"* ]]
}

# ── Self-registration mode (manual / legacy) ──────────────────────────────────

@test "preflight passes with root, tools, and E2E_API_KEY" {
  stub_root_env
  export E2E_API_KEY=key
  run preflight
  [ "$status" -eq 0 ]
}

# ── Endpoint requirements ─────────────────────────────────────────────────────
#
# Neither endpoint has a default any more. The old fallback was
# 172.16.230.168:31318, an RFC1918 address that silently pointed every external
# install at a gateway it could not route to.

@test "preflight fails when the gateway endpoint is unset (TIR mode)" {
  stub_root_env
  export E2E_TOKEN=tok E2E_PROJECT_ID=1557 E2E_LOG_GROUP=lg
  GATEWAY_ENDPOINT=""
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_GATEWAY_ENDPOINT is not set"* ]]
}

@test "preflight fails when the gateway endpoint is unset (self-registration)" {
  stub_root_env
  export E2E_API_KEY=key
  GATEWAY_ENDPOINT=""
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_GATEWAY_ENDPOINT is not set"* ]]
}

@test "self-registration requires the register endpoint" {
  stub_root_env
  export E2E_API_KEY=key
  REGISTER_API=""
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"E2E_REGISTER_API is not set"* ]]
}

@test "TIR-provisioned mode does NOT require the register endpoint" {
  # TIR already registered; requiring the address here would break every
  # install that goes through the console button.
  stub_root_env
  export E2E_TOKEN=tok E2E_PROJECT_ID=1557 E2E_LOG_GROUP=lg
  REGISTER_API=""
  run preflight
  [ "$status" -eq 0 ]
}
