# VPS Monitoring (Docker Compose)

This repository provides a minimal **Docker Compose** setup to monitor a VPS host, its Docker containers, and the Traefik access log that Dokploy writes.

It runs:

- **node_exporter**: host-level metrics (CPU, RAM, disk, filesystem, etc.)
- **cAdvisor**: container-level metrics (CPU/RAM/IO per container)
- **alloy**: ships the Traefik access log to a central Loki

> This repo does **not** include Prometheus/Grafana/Loki. It is the **collector** side: you need a Prometheus server that scrapes the exporters, and a Loki endpoint that Alloy can push to.

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

| Service       | Purpose                       | Port   | URL                                                             |
| ------------- | ----------------------------- | ------ | --------------------------------------------------------------- |
| node_exporter | Host metrics exporter         | `9100` | `http://<VPS_IP>:9100/metrics`                                  |
| cAdvisor      | Docker/container metrics      | `8080` | `http://<VPS_IP>:8080/` (UI) and `http://<VPS_IP>:8080/metrics` |
| alloy         | Traefik log shipper → Loki    | —      | no published port (push only; UI on `12345` inside the container) |

---

## Configuration

Every variable this stack reads lives in [`env.example`](env.example). Copy it and fill in the real values:

```bash
cp env.example .env
```

`.env` is git-ignored; `env.example` is tracked, so keep it free of real secrets.

| Variable        | Required | Read by | Description                                                     |
| --------------- | -------- | ------- | --------------------------------------------------------------- |
| `VPS_NAME`      | yes      | alloy   | Identifies this VPS in every log stream (label `vps`)           |
| `LOKI_PUSH_URL` | yes      | alloy   | Full Loki push endpoint, including the `/loki/api/v1/push` path |
| `LOKI_USER`     | no       | alloy   | Basic auth user for Loki (requires the edits below)             |
| `LOKI_PASSWORD` | no       | alloy   | Basic auth password for Loki (requires the edits below)         |

`node_exporter` and `cadvisor` read no environment variables.

`VPS_NAME` and `LOKI_PUSH_URL` are declared with `${VAR:?Set VAR}` in the compose file, so `docker compose` **refuses to start** while either is missing instead of shipping logs with no `vps` label. Verify your `.env` before starting:

```bash
docker compose --env-file env.example config
```

If your Loki needs authentication, three edits are required, all listed in `env.example`:

1. Uncomment `LOKI_USER` / `LOKI_PASSWORD` in `.env`
2. Add both to the alloy service's `environment:` list in `docker-compose.yml`
3. Uncomment the `basic_auth` block at the bottom of `files/config.alloy`

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
docker compose logs -f alloy
```

Validate the Alloy config without restarting the service:

```bash
docker compose exec alloy alloy fmt /etc/alloy/config.alloy
```

Stop:

```bash
docker compose down
```

Remove the Alloy positions/data volume too:

```bash
docker compose down -v
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

## Logs (Alloy → Loki)

`alloy` tails `/var/log/traefik/access.log`, labels every stream with `job="traefik"` and `vps="$VPS_NAME"`, and pushes to `LOKI_PUSH_URL`.

The pipeline in `files/config.alloy` handles **both** Traefik access log formats, so you can switch format later without editing it:

| Format                    | How it is parsed  | Labels available                    |
| ------------------------- | ----------------- | ----------------------------------- |
| `common` (Traefik default) | `stage.regex`     | `method`, `status`                  |
| `json`                    | `stage.json`      | `method`, `status`, `router`, `service` |

`router` and `service` only exist in JSON access logs: the CLF format does not contain them. To get them, set `accessLog.format: json` in your Traefik static config.

`client_ip` and `path` are extracted but deliberately **not** turned into labels: they are high-cardinality and would blow up the Loki index.

Query in Grafana:

```logql
{job="traefik", vps="vps-1"} |= "500"
{job="traefik", vps="vps-1", status="502"}
```

---

## Dokploy notes

If you paste this compose into a Dokploy **Compose** service, two things differ from running it in this repo:

1. **The config mount path.** Dokploy keeps the compose file at `/etc/dokploy/compose/<app>/code/docker-compose.yml`, so its "files" directory is one level up. Change:

   ```yaml
   - ./files/config.alloy:/etc/alloy/config.alloy:ro
   ```

   to:

   ```yaml
   - ../files/config.alloy:/etc/alloy/config.alloy:ro
   ```

   This is the only line that changes.

   Then create the config file in the Dokploy UI (**Advanced → Mounts → File Mount**):

   | Field      | Value                                |
   | ---------- | ------------------------------------ |
   | File Path  | `config.alloy`                       |
   | Mount Path | `/etc/alloy/config.alloy`            |
   | Content    | the contents of `files/config.alloy` |

2. **The log source.** `/etc/dokploy/traefik/dynamic` already holds `access.log` on a Dokploy host. On a plain VPS without Dokploy, point that mount at whatever directory your Traefik instance writes access logs to, and adjust `__path__` in `files/config.alloy` to match.

### Two copies of `config.alloy`

The Dokploy File Mount writes its own file, and that is the one the container actually runs:

| Copy       | Path                                              | Used by                            |
| ---------- | ------------------------------------------------- | ---------------------------------- |
| Repository | `files/config.alloy`                              | `docker compose` on this checkout  |
| Dokploy    | `/etc/dokploy/compose/<app>/files/config.alloy`   | the deployed service               |

They are independent files. Editing and committing the repository copy does **not** change the deployed pipeline: paste the updated content into the File Mount (Dokploy keeps it across deployments), or the VPS keeps shipping logs through the old config with no error to tell you.

Set `VPS_NAME` and `LOKI_PUSH_URL` in the Dokploy Environment tab. Dokploy injects them as compose environment variables, so no `.env` file is needed there.

`config.alloy` is bind-mounted read-only, so restarting the service is enough to pick up edits:

```bash
docker compose restart alloy
```

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

For `alloy` itself:

- It runs as UID/GID `473` (the `alloy` user in the image), with `cap_drop: ALL` and `no-new-privileges:true`
- It mounts the Traefik log directory **read-only** and never publishes a port
- It does send log lines off the box to `LOKI_PUSH_URL`: treat that endpoint as a data-egress boundary and keep it on a private network when possible

---

## Troubleshooting

**Alloy restarts in a loop.** Check `docker compose logs alloy`. The usual causes:

- `files/config.alloy` missing (Docker creates a *directory* at that path and Alloy finds no config)
- `VPS_NAME` or `LOKI_PUSH_URL` unset (compose fails before starting)
- The `alloy_data` volume already existed owned by root, so UID 473 cannot write the positions file. Fix with `docker compose down -v`, or `docker run --rm -v <project>_alloy_data:/d alpine chown 473:473 /d`

**Alloy runs but Loki receives nothing.** Check that `/var/log/traefik/access.log` exists inside the container:

```bash
docker compose exec alloy ls -l /var/log/traefik
```

If the file is missing, Traefik is not writing access logs, or the mount points at the wrong directory.

**Logs arrive without `router`/`service` labels.** Expected with the `common` access log format. Switch Traefik to `accessLog.format: json`.

---

## What this is (and what it isn’t)

✅ Good for:

- Exporting host + container metrics from a VPS
- Forwarding Traefik access logs from a VPS to a central Loki
- Feeding a central Prometheus/Grafana/Loki stack

❌ Not included:

- Prometheus
- Loki
- Grafana dashboards
- Alertmanager rules
- Docker container *stdout* logs (only the Traefik access log is shipped; add a `loki.source.docker` component if you need those)

If you want, the next logical step is to add a full monitoring stack (Prometheus + Grafana + Alertmanager + Loki) _or_ keep this repo as a clean "agent/collector" bundle and manage the server side centrally.
