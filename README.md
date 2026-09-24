# E2E OTel Collector

This repository builds the E2E OpenTelemetry Collector and provides a Linux VM installer. The [E2E Networks open source page](https://e2enetworks-oss.github.io/otel-collector/) links to this collector, its downloads, and other public projects.

## Install on a Linux VM

You need root access, systemd, `curl`, `mktemp`, and either `sha256sum` or `shasum`. Linux amd64 and arm64 are supported. If `jq` is not present, the installer downloads a pinned, checksum-verified copy from GitHub Releases to a temporary directory and removes it afterward.

Create a personal access token in MyAccount → API IAM, then run:

```bash
E2E_PERSONAL_ACCESS_TOKEN=<your-personal-access-token> \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

The installer registers a collector agent through `POST /api/v1/gpu/signals/agents`. The Signals API must return `agent_id`, `ingestion_token`, `project_id`, and `log_group`. The installer prints the agent ID and saves it with the collector configuration. It does not save the personal access token.

The installer checks gateway connectivity and verifies the binary against the published SHA-256 checksum. Its output marks each phase as `STEP`, `PASS`, `WARN`, or `FAIL`, with color on interactive terminals. An active service confirms that the collector started; check your Signals data to confirm telemetry arrived.

### Other deployments

| Variable | Default | Purpose |
|---|---|---|
| `E2E_PERSONAL_ACCESS_TOKEN` | Required | Personal access token from MyAccount → API IAM. |
| `E2E_API` | `api.e2enetworks.com` | API origin. A bare host uses HTTPS; `http://host:port` works for an internal NodePort. The installer adds the registration path. |
| `E2E_INTERNAL_GATEWAY` | `signals.e2enetworks.net:4317` | OTLP/gRPC destination. Use a host or `host:port`. A gateway returned by the API overrides this default. |

For example:

```bash
E2E_PERSONAL_ACCESS_TOKEN=<token> E2E_API=http://10.0.0.5:31881 \
  E2E_INTERNAL_GATEWAY=10.0.0.5:31318 \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

For a nonproduction API, provide `E2E_INTERNAL_GATEWAY` or have that API return `gateway_endpoint`. An explicitly set gateway takes priority over the API response. Re-running the installer updates the local files; the Signals API must return the same agent ID for the same token and hostname.

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
