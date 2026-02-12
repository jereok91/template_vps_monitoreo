# VPS Monitoring (Docker Compose)

This repository provides a minimal **Docker Compose** setup to monitor a VPS host and its Docker containers.

It runs:

- **node_exporter**: host-level metrics (CPU, RAM, disk, filesystem, etc.)
- **cAdvisor**: container-level metrics (CPU/RAM/IO per container)

> This repo does **not** include Prometheus/Grafana. This is only the **exporters** side. You need a Prometheus server (local or central) that scrapes these endpoints.

---

## Requirements

- A Linux VPS with Docker installed
- Docker Compose (plugin or standalone)

Quick sanity check:

```bash
docker --version
docker compose version
```

---

## Services & Ports

| Service       | Purpose                  | Port   | URL                                                             |
| ------------- | ------------------------ | ------ | --------------------------------------------------------------- |
| node_exporter | Host metrics exporter    | `9100` | `http://<VPS_IP>:9100/metrics`                                  |
| cAdvisor      | Docker/container metrics | `8080` | `http://<VPS_IP>:8080/` (UI) and `http://<VPS_IP>:8080/metrics` |

---

## Run

From the repository directory:

```bash
docker compose up -d
```

Check status:

```bash
docker compose ps
```

View logs:

```bash
docker compose logs -f
```

Stop:

```bash
docker compose down
```

---

## Prometheus (how to scrape these exporters)

On your Prometheus server, add scrape jobs like:

```yaml
scrape_configs:
  - job_name: "vps-node-exporter"
    static_configs:
      - targets: ["<VPS_IP>:9100"]

  - job_name: "vps-cadvisor"
    static_configs:
      - targets: ["<VPS_IP>:8080"]
```

Then reload Prometheus.

---

## Security Notes (don’t be reckless)

Right now this compose file publishes metrics endpoints to the network:

- `9100:9100`
- `8080:8080`

That’s fine for a private network, but on a public VPS you should **NOT** leave these ports open to the whole internet.

Recommended options:

- Restrict access via firewall (UFW / security groups): allow only your Prometheus server IP
- Run behind a VPN (Tailscale / WireGuard)
- Bind to localhost and scrape via SSH tunnel / reverse proxy (advanced)

---

## What this is (and what it isn’t)

✅ Good for:

- Exporting host + container metrics from a VPS
- Feeding a central Prometheus/Grafana monitoring stack

❌ Not included:

- Prometheus
- Grafana dashboards
- Alertmanager rules

If you want, the next logical step is to add a full monitoring stack (Prometheus + Grafana + Alertmanager + Loki) _or_ keep this repo as a clean “agent/exporter” bundle and manage Prometheus centrally.
