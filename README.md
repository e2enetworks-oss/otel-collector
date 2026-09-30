# E2E OTel Collector

This repository provides an E2E installer and configuration for the official OpenTelemetry Collector Contrib distribution (`otelcol-contrib`). It downloads upstream version **0.162.0** and verifies the archive against the upstream SHA-256 checksum before installation. The collector can run on hosts and VMs, or in containers on Kubernetes. The [E2E Networks open source page](https://e2enetworks-oss.github.io/otel-collector/) links to this collector, its downloads, and other public projects.

## Install on Linux

You need root access, systemd, `curl`, `tar`, `mktemp`, and either `sha256sum` or `shasum`. Linux amd64 and arm64 are supported. If `jq` is not present, the installer downloads a pinned, checksum-verified copy from GitHub Releases to a temporary directory and removes it afterward.

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
| `E2E_INTERNAL_GATEWAY` | `signals.e2enetworks.net:4317` | OTLP/gRPC destination. Use a host or `host:port`. A gateway returned by the API overrides this default. |

For example:

```bash
E2E_PERSONAL_ACCESS_TOKEN=<token> E2E_API=http://10.0.0.5:31881 \
  E2E_INTERNAL_GATEWAY=10.0.0.5:31318 \
  bash -c "$(curl -fsSL https://e2enetworks-oss.github.io/otel-collector/install.sh)"
```

## Downloads

The [downloads page](https://e2enetworks-oss.github.io/otel-collector/) provides the E2E installer and VM configuration, with links to the [official upstream archives and checksums](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.162.0). Linux amd64 and arm64 are supported by the installer. Windows binaries are available upstream; this installer requires Linux and systemd.

The existing E2E service name, binary path, registration, credentials, and configuration paths are retained when switching to the upstream binary. We maintain no custom collector components or Go build pipeline. The custom gateway is maintained separately in the observability platform repository.

## Development

The VM configuration is in `samples/vm-config.yaml`, the installer is `install.sh`, and the landing page is `site/index.html`. The upstream version is pinned by `OTELCOL_VERSION` in `install.sh`; update the download links here and on the landing page when changing it.

Running the local checks requires ShellCheck, jq, and Bats:

```bash
make lint
make test
```

Continuous Integration (CI) runs these checks and validates the VM configuration using the verified upstream collector binary. GitHub Pages publishes the installer and configuration after changes on `main`.
