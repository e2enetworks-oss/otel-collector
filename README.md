# E2E OTel Collector

A custom [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) distribution for E2E Networks, plus the installer that turns a Linux VM into an E2E Observability Agent.

The repo owns three things:

1. **Builder manifests** (`collector/`) — which OTel components go into the binary.
2. **CI** (`.github/workflows/`) — builds, releases and publishes it for Linux amd64/arm64 and Windows amd64.
3. **The installer** (`install.sh` + `samples/vm-config.yaml`) — what end users run.

There is no hand-written collector Go source here. `main.go` and `components.go` are generated at build time by [ocb](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) from the manifests, compiled in CI, and never committed.

---

## Install

```bash
E2E_PERSONAL_ACCESS_TOKEN=<your-personal-access-token> \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

Root, systemd, `curl`, and a Linux VM on amd64 or arm64. Your personal access token is the only required value. The installer sends the detected hostname to the Signals API and receives a separate ingestion token, project ID, and log group. If the API returns `agent_id`, the installer shows that collector agent ID and saves it locally. The personal access token is not written to the collector's env file.

Full operator guide, including verification and uninstall: [Install the Virtual Machine Collector](https://runbooks.e2enetworks.net/observability/agents/vm/install) (internal).

### Pointing at a different deployment

Engineers installing against a dev stack can select its API origin and gateway:

| Variable | Default | Use when |
|---|---|---|
| `E2E_PERSONAL_ACCESS_TOKEN` | — **required** | Always. From MyAccount → API IAM. |
| `E2E_API` | `https://api.e2enetworks.com` | API origin. A bare host uses HTTPS; use `http://host:port` for an internal NodePort. The installer appends `/v1/install/register`. |
| `E2E_INTERNAL_GATEWAY` | `signals.e2enetworks.net` | Signals go somewhere other than production. Hostname, or `host:port` when it is not on `4317`. |

```bash
E2E_PERSONAL_ACCESS_TOKEN=<token> E2E_API=http://10.0.0.5:31881 \
  E2E_INTERNAL_GATEWAY=10.0.0.5:31318 \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

If registration returns a `gateway_endpoint`, it beats the production default. An explicitly set `E2E_INTERNAL_GATEWAY` wins over the response. When `E2E_API` points away from production, the installer requires one of those gateway values so it cannot silently ship a dev tenant's signals to production.

The installer refuses to finish if it cannot open a TCP connection to the default gateway. An unreachable gateway does not stop the collector — the service stays `active`, retries each batch for five minutes and then drops it. A gateway you set explicitly or the API supplies warns instead and continues when the TCP check fails.

It also verifies the downloaded binary against the published `checksums.txt` and refuses on a mismatch, on an unlisted file, or when the manifest cannot be fetched. A failed install leaves no partial binary behind.

Re-running the installer on the same VM rewrites the config, env file and unit. The Signals API must keep registration idempotent for the same personal access token and hostname so reruns keep the same collector agent ID.

Install output shows each phase as `STEP`, `PASS`, `WARN`, or `FAIL`, with colors on interactive terminals. It stays plain when piped or when `NO_COLOR` is set. Registration warns if the API omits `agent_id`; service `PASS` means systemd reports it active, not that telemetry has reached the gateway.

---

## Architecture

One binary runs everywhere. Which components are active is decided by the config file passed at startup (`--config=...`), not by a rebuild — `samples/vm-config.yaml` wires up only `hostmetrics`, `journald` and `filelog`, leaving the Kubernetes components compiled in but idle.

| | Components |
|---|---|
| Receivers | `otlp`, `filelog`, `journald`, `hostmetrics`, `kubeletstats`, `prometheus` |
| Processors | `memory_limiter`, `resource`, `k8sattributes`, `batch` |
| Exporters | `otlp/gateway` — gRPC to the E2E gateway, token auth |
| Extensions | `health_check` (:13133), `file_storage` (offset checkpoints) |

Signals leave the agent over OTLP/gRPC to the E2E Observability Gateway, and from there to NATS → Vector → ClickHouse.

Two manifests build two variants:

| Manifest | Platform | Difference |
|---|---|---|
| `collector/builder-config.yaml` | Linux amd64, arm64 | Full set, including `journaldreceiver` (needs `libsystemd`, so CGO on) |
| `collector/builder-config-windows.yaml` | Windows amd64 | No `journaldreceiver` — no systemd journal on Windows, and it is CGO-only |

---

## Layout

```
collector/            ocb manifests (Linux + Windows)
samples/              reference OTel pipeline config for VM installs
install.sh            the VM installer
tests/install.bats    unit tests for install.sh's pure functions
.github/workflows/    release, pages, lint, gitleaks
Makefile              make lint / make test / make changelog
```

---

## Development

```bash
make help                      # list targets
make lint                      # shellcheck install.sh (+ go vet once Go source lands)
make test                      # bats tests/
make changelog VERSION=x.y.z   # prepend a CHANGELOG entry from git log since the last tag
```

CI runs `make lint` then `make test` on every push and PR; gitleaks scans separately.

`install.sh`'s testable logic — `resolve_endpoints`, `normalize_gateway`, `preflight`, `detect_arch`, `parse_field`, `checksum_for`, `gateway_reachable`, `posthog_capture` — is written as pure functions behind a `BASH_SOURCE` guard, so the bats suite sources the script without running the installer.

### Install telemetry

The installer posts a `vm_agent_installed` event to PostHog after the service starts, carrying architecture, distribution, API host, gateway and binary name, keyed by a SHA-256 of the hostname. It is best-effort and never fails an install.

**No key is committed.** `posthog_capture` does nothing unless `E2E_POSTHOG_KEY` is set (with `E2E_POSTHOG_HOST` defaulting to `https://app.posthog.com`). Which project, which region, and whether an install event may carry `customer_id`/`project_id` are decisions for the maintainer, not defaults for a script to pick.

Two things to know about the suite before trusting it:

- `setup()` must leave errexit **on**. bats decides pass/fail from it, and a `set +e` there makes every assertion in the file advisory — `[ 1 -eq 2 ]` reports `ok`.
- With errexit on, a failing test prints no `not ok` line. It vanishes from the output and bats reports `Executed N instead of expected M` with exit 1. **Gate on the exit code, never on grepping `not ok`.**

Mutation-check after changing the suite: break one assertion and confirm `bats tests/` exits non-zero.

---

## Builds and releases

1. CI installs the pinned ocb (`go install go.opentelemetry.io/collector/cmd/builder@v0.148.0`).
2. ocb reads a manifest and generates `main.go`, `components.go` and `go.mod` under `collector/dist/`.
3. `go build` compiles that generated module.

| Binary | Runner | GOOS/GOARCH | CGO |
|---|---|---|---|
| `e2e-otel-collector-linux-amd64` | `ubuntu-latest` | linux/amd64 | on |
| `e2e-otel-collector-linux-arm64` | `ubuntu-24.04-arm` | linux/arm64 | on |
| `e2e-otel-collector-windows-amd64.exe` | `ubuntu-latest` (cross) | windows/amd64 | off |

Releases are cut from a `v*` tag pushed by a human — there is no auto-tag on merge. The `verify-tag` job enforces that the tag matches `otelcol_version` in `collector/builder-config.yaml`; a `-e2e.N` suffix allows several E2E builds off one upstream version (`v0.148.0-e2e.1`). `workflow_dispatch` re-runs a release for an existing tag.

On release, the three binaries and `checksums.txt` attach to a GitHub Release, and the same run mirrors them — plus `install.sh` and `samples/` — to <https://e2enetworks-oss.github.io/otel-collector/>, which is where `install.sh` downloads from. `pages.yaml` re-deploys that site whenever `install.sh` or `samples/` change on `main`, re-mirroring the binaries so a docs-only change never wipes them.
