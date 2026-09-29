# E2E OTel Collector

This repository builds the E2E OpenTelemetry Collector and provides an installer. The collector can run on hosts and VMs, or in containers on Kubernetes. The [E2E Networks open source page](https://e2enetworks-oss.github.io/otel-collector/) links to this collector, its downloads, and other public projects.

## Install on Linux

You need root access, systemd, `curl`, `mktemp`, and either `sha256sum` or `shasum`. Linux amd64 and arm64 are supported. If `jq` is not present, the installer downloads a pinned, checksum-verified copy from GitHub Releases to a temporary directory and removes it afterward.

Create a personal access token in TIR > Personal access token, then run:

```bash
E2E_PERSONAL_ACCESS_TOKEN=<your-personal-access-token> \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

### Other deployments

| Variable | Default | Purpose |
|---|---|---|
| `E2E_PERSONAL_ACCESS_TOKEN` | Required | Personal access token from TIR > Personal access token. |
| `E2E_API` | `api.e2enetworks.com` | API origin. A bare host uses HTTPS; `http://host:port` works for an internal NodePort. The installer adds the registration path. |
| `E2E_GATEWAY_ENDPOINT` | `signals.e2enetworks.net:4317` | OTLP/gRPC destination. Use a host or `host:port`. A gateway returned by the API overrides this default. |

For example:

```bash
E2E_PERSONAL_ACCESS_TOKEN=<token> E2E_API=http://10.0.0.5:31881 \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

### What the installer asks the API for

With the default `observability` registration, the installer reads this host's
name and makes one authenticated request:

```
GET  <E2E_API>/api/v1/gpu/observability/tokens/?hostname=<this host>
     Authorization: Bearer <E2E_PERSONAL_ACCESS_TOKEN>
```

The project is read from the token's own record, so no project id is sent and
none can be guessed. The reply carries everything the collector needs:

| Field | Used for |
|---|---|
| `ingestion_token` | the credential the collector presents to the gateway on every batch |
| `project_id` | stamped on telemetry, and the column dashboards filter on |
| `customer_id` | the owning account — displayed during install, never stored on the host |
| `log_group` | this host's telemetry stream |
| `gateway_endpoint` | where to ship; overrides the built-in default, so the address need not be published |

Sending the hostname is what gives each host its own log group and its own
ingestion token, so one compromised host cannot forge telemetry for the rest of
the project and rotating one token does not take the fleet down. Repeat calls for
the same host return the same token, so re-running the installer is safe.

## Downloads

The [downloads page](https://e2enetworks-oss.github.io/otel-collector/) provides the installer, VM configuration, Linux binaries, and checksums. Binaries and checksums are mirrored from the latest GitHub Release. The [release workflow](.github/workflows/release.yaml) also builds a Windows amd64 binary.

## Development

The collector components are defined in `collector/`. The VM configuration is in `samples/vm-config.yaml`, the installer is `install.sh`, and the landing page is `site/index.html`.

Running the local tests requires `jq` and Bats.

```bash
make lint
make test
```

CI builds Linux amd64, Linux arm64, and Windows amd64 binaries. A `v*` tag runs the release workflow. The [Pages workflow](.github/workflows/pages.yaml) republishes the landing page and installer assets after changes on `main`.
