# E2E OTel Collector

A custom-built [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) distribution for E2E Networks. It assembles a single, purpose-built binary (`e2e-otel-collector-app`, shipped to users as `e2e-otelcol`) via the [OpenTelemetry Collector Builder (ocb)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder), and provides the installer + reference config that turn any Linux VM into an E2E Observability Agent in about two minutes.

This repo owns three things:

1. **The builder manifests** (`collector/`) that define which OTel components go into the binary.
2. **The CI pipeline** (`.github/workflows/`) that builds, releases, and publishes that binary for Linux (amd64/arm64) and Windows (amd64).
3. **The VM installer** (`install.sh` + `samples/vm-config.yaml`) that end users run to deploy the agent.

There is no hand-written collector Go source in this repo — the binary's `main.go`/`components.go` are generated at build time by `ocb` from the manifests below and compiled directly in CI. Nothing under `collector/dist*` is committed (see `.gitignore` / `.gitleaks.toml`).

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         e2e-otelcol (single binary)                  │
│                                                                        │
│  Receivers                Processors              Exporters          │
│  ──────────               ───────────              ─────────         │
│  otlp            ──┐                                                 │
│  filelog            │     memory_limiter                             │
│  journald   ────────┼──▶  resource         ──▶   otlp/gateway ───────┼──▶ E2E
│  hostmetrics         │    k8sattributes           (gRPC, mTLS/token)  │   Observability
│  kubeletstats        │    batch                                      │   Gateway
│  prometheus  ───────┘                                                │   (NATS → Vector →
│                                                                        │    ClickHouse)
│  Extensions: health_check (13133), file_storage (offset checkpoints) │
└──────────────────────────────────────────────────────────────────────┘
        ▲                              ▲
        │ runs as                      │ runs as
   systemd service                DaemonSet / sidecar
   on a Linux VM                  on Kubernetes
```

The binary is **environment-agnostic** — the same compiled artifact runs on a bare VM (as a systemd service) or inside Kubernetes (as a DaemonSet). Which receivers/processors are actually active is decided entirely by the **config file** handed to it at startup (`--config=...`), not by a rebuild. For example, `samples/vm-config.yaml` only wires up `hostmetrics`, `journald`, and `filelog` for the VM use case; `kubeletstats` and `k8sattributes` are compiled in but simply unused unless a Kubernetes config enables them.

Two builder manifests produce two variants of the same binary:

| Manifest | Platform | Notes |
|---|---|---|
| `collector/builder-config.yaml` | Linux (amd64, arm64) | Full component set, including `journaldreceiver` (needs `libsystemd`/CGO) |
| `collector/builder-config-windows.yaml` | Windows (amd64) | Identical, minus `journaldreceiver` — no systemd journal on Windows, and it's CGO-only anyway |

---

## Repo layout

```
.
├── collector/
│   ├── builder-config.yaml          # ocb manifest — Linux (amd64/arm64) build
│   └── builder-config-windows.yaml  # ocb manifest — Windows build (no journaldreceiver)
├── samples/
│   └── vm-config.yaml               # Reference OTel pipeline config for VM installs
├── install.sh                       # VM installer (registers, downloads binary, installs systemd unit)
├── tests/
│   └── install.bats                 # bats unit tests for install.sh's pure functions
├── .github/workflows/
│   ├── release.yaml                 # Build matrix, GitHub Release, Pages mirror
│   ├── pages.yaml                   # Re-publish install assets when install.sh/samples change
│   ├── lint.yaml                    # shellcheck + go vet/lint + bats, on every push/PR
│   └── gitleaks.yml                 # Secret scanning on every push/PR
├── .golangci.yml                    # Lint rules for the (future) hand-written Go source
├── .gitleaks.toml                   # Secret-scan allowlist (ocb output, ${env:...} placeholders)
├── Makefile                         # make lint / make test / make changelog
└── CHANGELOG.md                     # Generated via `make changelog VERSION=x.y.z`
```

---

## How the binary is built

The collector's Go source does not live in this repo — it's generated fresh on every build:

1. CI installs the pinned `ocb` (`go install go.opentelemetry.io/collector/cmd/builder@v0.148.0`).
2. `ocb` reads the manifest (`collector/builder-config.yaml` or `-windows.yaml`) and generates `main.go`, `components.go`, and a `go.mod` under `collector/dist/` (or `dist-win/`) wiring up exactly the receivers/processors/exporters/extensions listed.
3. `go build` compiles that generated module into the final binary.

This is why `Makefile`'s `lint-go` / `fmt` / `vet` targets currently no-op — there's no `go.mod` checked into the repo for them to find, only the manifests that describe what `ocb` should generate. If hand-written custom components are added later, they'd land as their own Go module and these targets pick them up automatically (see the comment at the top of the `Makefile`).

### Build matrix (`.github/workflows/release.yaml`)

| Binary | Runner | GOOS/GOARCH | CGO | Builder config |
|---|---|---|---|---|
| `e2e-otel-collector-linux-amd64` | `ubuntu-latest` | linux/amd64 | on (needs `libsystemd-dev` for journald) | `builder-config.yaml` |
| `e2e-otel-collector-linux-arm64` | `ubuntu-24.04-arm` | linux/arm64 | on | `builder-config.yaml` |
| `e2e-otel-collector-windows-amd64.exe` | `ubuntu-latest` (cross-compiled) | windows/amd64 | off | `builder-config-windows.yaml` |

### Release & versioning contract

- Releases are cut from a `v*` git tag (e.g. `v0.148.0`), pushed by a human — there's no auto-tag-on-merge.
- The `verify-tag` job enforces that a tag's version **matches** `otelcol_version` in `collector/builder-config.yaml`. A `-e2e.N` build suffix is allowed for multiple E2E builds off the same upstream OTel version (e.g. `v0.148.0-e2e.1`).
- `workflow_dispatch` lets you re-run a release for an existing tag without re-pushing it.
- On release, all three binaries + `checksums.txt` are attached to a GitHub Release, and the same run's `mirror-pages` job republishes them (plus `install.sh` and `samples/vm-config.yaml`) to GitHub Pages at `https://e2enetworks-oss.github.io/otel-collector/` — this is the URL `install.sh` downloads from.
- `pages.yaml` separately re-deploys the Pages site whenever `install.sh` or `samples/` change on `main`, so a docs-only change never goes stale or wipes the mirrored binaries.

---

## Development

```bash
make help        # list all targets
make lint         # shellcheck install.sh + go vet/golangci-lint (no-op until Go source lands)
make test         # bats tests/  — unit tests for install.sh's pure functions
make fmt          # gofmt -w -s (no-op until Go source lands)
make changelog VERSION=x.y.z   # prepend a CHANGELOG.md entry from git log since the last tag
```

CI (`lint.yaml`) runs `make lint` then `make test` on every push/PR to `main`. `gitleaks.yml` scans for committed secrets on every push/PR; `.gitleaks.toml` allowlists `collector/dist*` (ocb-generated output) and `${env:VAR}` placeholders in configs.

`install.sh`'s testable logic (`detect_arch`, `parse_field`, `preflight`) is written as pure functions and guarded behind a `BASH_SOURCE` check so `tests/install.bats` can `source` the script without triggering `main()`.

---

## Install (end users)

Install the E2E Observability Agent on your Linux VM to start collecting logs and metrics in your E2E dashboard within 2 minutes.

### Requirements

- Linux VM (x86_64 or ARM64)
- Running as **root**
- `curl` installed
- systemd-based OS (Ubuntu, AlmaLinux, RHEL, Debian, etc.)

### Install

```bash
E2E_API_KEY=<your-api-key> \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

| Variable | Where to find it |
|---|---|
| `E2E_API_KEY` | MyAccount → API IAM |

`project_id` and `customer_id` are no longer supplied by hand — the register call derives both deterministically from the API key server-side and returns `project_id` in the response, same as it already does for `log_group`.

The install command is **idempotent** — safe to re-run on the same VM to update or repair the agent.

What the installer actually does (see `install.sh`):

1. **Preflight** — checks root, `curl`, `systemctl`, and required env vars.
2. **Detect platform** — maps `uname -m` to `amd64`/`arm64`.
3. **Register** — `POST`s to `https://obs.e2enetworks.net/v1/install/register` with the API key and sanitized hostname; gets back an `ingestion_token`, `log_group`, and `project_id`. The hostname gives each VM its own log group (`logs.infra.vm.<project_id>.<host>`).
4. **Download binary** — pulls `e2e-otel-collector-linux-<arch>` from GitHub Pages into `/usr/local/bin/e2e-otelcol`.
5. **Write config** — env file (mode 600, credentials) at `/etc/e2e-otel-collector/env`, and `samples/vm-config.yaml` (via Pages) at `/etc/e2e-otel-collector/config.yaml`.
6. **Install & start** the systemd unit, enabling it and (re)starting the service.

### What gets collected

| Data | Source |
|---|---|
| CPU utilization | `/proc/stat` — per core, every 30s |
| Memory utilization | `/proc/meminfo` — every 30s |
| Disk I/O | `/proc/diskstats` — every 30s |
| Network I/O | `/proc/net/dev` — every 30s |
| Filesystem usage | `statfs()` — every 30s |
| Load average | `/proc/loadavg` — every 30s |
| Systemd journal logs | All services on the VM |
| Syslog / auth logs | `/var/log/messages`, `/var/log/secure` |
| Application logs | `/var/log/app/*.log`, `/var/log/python/*.log`, `/root/app/*.log`, `/opt/app/*.log` |

All of the above is defined in `samples/vm-config.yaml` — the `hostmetrics`, `journald`, and `filelog/*` receivers, tagged with `host.name`, `log_group`, and `project_id` resource attributes, batched, and shipped over OTLP/gRPC to the E2E gateway (`otlp/gateway` exporter) with token auth and retry-on-failure.

### What you see in the dashboard

Within 2 minutes of install, your VM appears in:

- **Grafana → Observability → Host Metrics** — CPU, memory, disk, network, filesystem panels
- **Grafana → Logging → OTel Logs** — all systemd and syslog entries, filterable by host

### Manage the agent

```bash
# Check status
systemctl status e2e-otel-collector

# Stream live agent logs
journalctl -u e2e-otel-collector -f

# Check health
curl -s http://localhost:13133

# Restart after a config change
systemctl restart e2e-otel-collector

# Stop and disable
systemctl stop e2e-otel-collector
systemctl disable e2e-otel-collector
```

### Files installed on the VM

```
/usr/local/bin/e2e-otelcol                        ← agent binary
/etc/e2e-otel-collector/config.yaml               ← pipeline config
/etc/e2e-otel-collector/env                        ← credentials (root-only)
/etc/systemd/system/e2e-otel-collector.service     ← systemd unit
/var/lib/e2e-otel-collector/                       ← state and checkpoints (file_storage extension)
```

### Uninstall

```bash
systemctl stop e2e-otel-collector
systemctl disable e2e-otel-collector
rm -f /usr/local/bin/e2e-otelcol
rm -rf /etc/e2e-otel-collector
rm -f /etc/systemd/system/e2e-otel-collector.service
systemctl daemon-reload
```