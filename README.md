# E2E OTel Collector

Custom OpenTelemetry Collector distribution for E2E Networks — collects logs, metrics, and traces from Linux VMs and Kubernetes clusters, and forwards them to the E2E observability platform.

## What's in this repo

| Path | Purpose |
|------|---------|
| `collector/builder-config.yaml` | OCB manifest for Linux builds (includes journaldreceiver) |
| `collector/builder-config-windows.yaml` | OCB manifest for Windows builds (journaldreceiver excluded) |
| `charts/otel-collector/` | Helm chart for Kubernetes DaemonSet deployment |
| `releases/latest/vm-config.yaml` | OTel Collector config template for VM deployments |

## Deployment

### Linux / Windows VM

1. Download the binary for your platform from [Releases](../../releases/latest):
   - `otelcol-linux-amd64` — Linux x86_64
   - `otelcol-linux-arm64` — Linux ARM64
   - `otelcol-windows-amd64.exe` — Windows x86_64

2. Install the binary:
   ```bash
   sudo install -o root -g root -m 0755 otelcol-linux-amd64 /usr/local/bin/e2e-otel-collector
   ```

3. Drop the config in place:
   ```bash
   sudo mkdir -p /etc/e2e-otel-collector
   sudo cp vm-config.yaml /etc/e2e-otel-collector/config.yaml
   ```

4. Set required environment variables in `/etc/e2e-otel-collector/env`:
   ```
   HOST_NAME=<this-vm-hostname>
   CLUSTER_INGESTION_TOKEN=<token-from-CreateLogGroup>
   ```

5. Install and start the systemd service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now e2e-otel-collector
   ```

What it collects on a VM: systemd journal logs, syslog/auth files, app logs under `/var/log/`, and host OS metrics (CPU, memory, disk, network).

---

### Kubernetes (Helm)

```bash
helm install otel-collector ./charts/otel-collector \
  --namespace e2e-monitoring --create-namespace \
  --set cluster.name=cluster2 \
  --set gateway.endpoint="<otel-gateway-nodeport-ip>:31318" \
  --set gateway.tokenSecret.name=cluster-ingestion-token \
  --set gateway.tokenSecret.key=token
```

Key values:

| Value | Required | Description |
|-------|----------|-------------|
| `cluster.name` | Yes | Cluster identifier stamped on all signals (e.g. `cluster2`) |
| `gateway.endpoint` | Yes | OTel Gateway NodePort address |
| `gateway.tokenSecret` | No | K8s secret containing the ingestion token |

The chart deploys a DaemonSet that collects: container logs via filelog, host metrics, kubelet stats, OTLP traces/metrics from app SDKs, and Hubble network flows (if Cilium is enabled).

---

## CI / CD

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `release.yaml` | Push to `main`/`otel-collector`, or `v*` tag | Builds binaries for linux/amd64, linux/arm64, windows/amd64. Creates a GitHub Release on `v*` tags. |
| `gitleaks.yml` | Push / PR | Scans for leaked secrets |
| `lint-charts.yaml` | Push / PR touching `charts/**` | Runs `helm lint` on the chart |

To ship a release:
```bash
git tag v1.0.0
git push origin v1.0.0
```

The pipeline builds all three binaries and attaches them to the GitHub Release along with `vm-config.yaml`.

## Build

Binaries are built using the [OTel Collector Builder (ocb)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder). The Linux binary includes `journaldreceiver` (systemd journal, Linux/CGO only). The Windows binary excludes it since Windows has no systemd.

To build locally:
```bash
go install go.opentelemetry.io/collector/cmd/builder@v0.148.0

# Linux
cd collector && builder --config=builder-config.yaml --skip-compilation=true
cd dist && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -trimpath -o e2e-otel-collector .

# Windows (cross-compile from Linux)
cd collector && builder --config=builder-config-windows.yaml --skip-compilation=true
cd dist-win && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -o e2e-otel-collector.exe .
```
