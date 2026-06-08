# E2E Observability Agent

Install the E2E Observability Agent on your Linux VM to start collecting logs and metrics in your E2E dashboard within 2 minutes.

---

## Requirements

- Linux VM (x86_64 or ARM64)
- Running as **root**
- `curl` installed
- systemd-based OS (Ubuntu, AlmaLinux, RHEL, Debian, etc.)

---

## Install

```bash
E2E_API_KEY=<your-api-key> \
E2E_PROJECT_ID=<your-project-id> \
E2E_CUSTOMER_ID=<your-customer-id> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/e2enetworks-oss/otel-collector/main/install.sh)"
```

| Variable | Where to find it |
|---|---|
| `E2E_API_KEY` | MyAccount → API IAM |
| `E2E_PROJECT_ID` | MyAccount → Projects |
| `E2E_CUSTOMER_ID` | MyAccount → Profile |

The install command is **idempotent** — safe to re-run on the same VM to update or repair the agent.

---

## What Gets Collected

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
| Application logs | `/var/log/app/*.log`, `/var/log/python/*.log` |

---

## What You See in the Dashboard

Within 2 minutes of install, your VM appears in:

- **Grafana → Observability → Host Metrics** — CPU, memory, disk, network, filesystem panels
- **Grafana → Logging → OTel Logs** — all systemd and syslog entries, filterable by host

---

## Manage the Agent

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

---

## Files Installed on the VM

```
/usr/local/bin/e2e-otelcol                        ← agent binary
/etc/e2e-otel-collector/config.yaml               ← pipeline config
/etc/e2e-otel-collector/env                        ← credentials (root-only)
/etc/systemd/system/e2e-otel-collector.service     ← systemd unit
/var/lib/e2e-otel-collector/                       ← state and checkpoints
```

---

## Uninstall

```bash
systemctl stop e2e-otel-collector
systemctl disable e2e-otel-collector
rm -f /usr/local/bin/e2e-otelcol
rm -rf /etc/e2e-otel-collector
rm -f /etc/systemd/system/e2e-otel-collector.service
systemctl daemon-reload
```
