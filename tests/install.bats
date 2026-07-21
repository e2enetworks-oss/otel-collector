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
  # source (otherwise the first non-zero command aborts it), then clear all three
  # afterward — nounset/pipefail would otherwise leak into every test and make a
  # future bare-$VAR reference fail confusingly. Tests own error handling via `run`.
  set +e
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/install.sh"
  set +euo pipefail
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

@test "preflight passes with root, tools, and E2E_API_KEY" {
  stub id <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
  stub systemctl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export E2E_API_KEY=key
  run preflight
  [ "$status" -eq 0 ]
}
