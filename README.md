# wf-adguard-nrd-feed

> Automated rolling-window NRD blocklist for AdGuard Home, powered by the WhoisFreaks daily domain feed. Zero-click setup, per-day caching, and daily auto-refresh — all in Docker.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-compose-2496ED.svg)](https://docs.docker.com/compose/)
[![AdGuard Home](https://img.shields.io/badge/AdGuard-Home-68BC71.svg)](https://adguard.com/en/adguard-home/overview.html)

---

## Why

Palo Alto Networks Unit 42 found that **more than 70% of domains registered in the previous 32 days were malicious, suspicious, or NSFW**. Curated threat feeds don't catch these domains until days after they're active. Blocking newly registered domains closes that gap at the DNS layer — before any connection is made.

---

## What you get

- **Rolling window blocking** — choose 5, 10, or 30 days. One env var.
- **Per-day caching** — only today's two new files download each night. No redundant API calls.
- **Zero-click setup** — AdGuard's setup wizard completes automatically. NRD filter is registered before AdGuard first starts.
- **Static feed server IP** — avoids AdGuard's DNS-resolution-of-itself problem that breaks HTTP filter subscriptions.
- **Daily auto-refresh** — cron rebuilds the feed and signals AdGuard to hot-reload. DNS service uninterrupted.
- **API key isolation** — key lives in one file on the host, mounted read-only. Never in compose files or logs.
- **Adblock-format output** — native `||domain^` syntax for best AdGuard compatibility and subdomain matching.

---

## Quick start

### 1. Free port 53 (Ubuntu only)

```bash
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

### 2. Store your API key

```bash
sudo mkdir -p /etc/whoisfreaks
echo "YOUR_WHOISFREAKS_API_KEY" | sudo tee /etc/whoisfreaks/apikey > /dev/null
sudo chmod 600 /etc/whoisfreaks/apikey
```

### 3. Set your password

Edit `docker-compose.yml` — find `ADGUARD_PASS` under both `feed-init` and `feed-fetcher` and set your chosen password:

```yaml
ADGUARD_PASS: "your-strong-password-here"
```

### 4. Start

```bash
docker compose up -d
docker logs -f nrd-feed-init   # watch the first fetch complete
```

Open **http://localhost** once the init container exits. Log in with `admin` and your password. The NRD blocklist will be in **Filters → DNS blocklists** with 3M+ rules.

---

## How it works

```
WhoisFreaks bulk download (gtld + cctld, gzipped, daily)
        │
        ▼
  nrd-feed-init  (runs once on first start, then exits)
        │  fetches window days → writes nrd.adblock → patches AdGuard config
        ▼
  adguard-home   (starts after init exits — NRD filter pre-registered)
        │
        ▼
  nrd-feed-fetcher  (runs daily cron)
        │  downloads newest day → prunes oldest → rebuilds nrd.adblock → triggers AdGuard refresh
        ▼
  nrd-feed-server   (nginx, static IP 172.28.0.10)
        │  serves nrd.adblock over HTTP to AdGuard
```

AdGuard's filter update API validates URLs by fetching them — using its own DNS resolver, not Docker's. Assigning the feed server a fixed IP (`172.28.0.10`) and hardcoding it in AdGuard's `/etc/hosts` via `extra_hosts` bypasses that resolution entirely.

---

## Configuration

All settings are in `docker-compose.yml` under `feed-init` and `feed-fetcher`:

| Variable | Default | Description |
|----------|---------|-------------|
| `WINDOW_DAYS` | `10` | Rolling window in days (5, 10, or 30 recommended) |
| `FEED_TYPES` | `gtld cctld` | Feed types — remove `cctld` to halve the domain count |
| `CRON_SCHEDULE` | `0 2 * * *` | Daily refresh time (UTC, cron syntax) |
| `ADGUARD_USER` | `admin` | AdGuard admin username |
| `ADGUARD_PASS` | *(required)* | AdGuard admin password — set before first run |

### Picking your window

| Window | ~Domains | False positive risk | Recommended for |
|--------|----------|---------------------|-----------------|
| 5 days | 1.3–1.5M | Low | Unpredictable traffic, minimal allowlist management |
| 10 days | 3–3.2M | Medium | Most home and small business setups |
| 30 days | 8–9M | Higher | Maximum coverage with active allowlist management |

---

## Project structure

```
wf-adguard-nrd-feed/
├── docker-compose.yml       ← four services: feed-init, adguard, feed-fetcher, feed-server
├── feed/
│   ├── Dockerfile           ← Alpine + bash + python3 + gzip
│   ├── fetch-nrd.sh         ← rolling-window NRD downloader and adblock builder
│   └── entrypoint.sh        ← init/cron mode dispatcher
├── reset-password.sh        ← wipes AdGuard config when password changes
├── .gitignore
├── LICENSE
└── README.md
```

Runtime directories (gitignored, created on first run):

```
adguard-data/                ← AdGuard persistent config and working data
feed/cache/                  ← per-day NRD files (persists across restarts)
feed/output/nrd.adblock      ← combined blocklist served to AdGuard
```

---

## Changing your password

AdGuard stores its password hash in `adguard-data/conf/AdGuardHome.yaml`. Updating `ADGUARD_PASS` in the compose file alone doesn't change it. Use the helper:

```bash
chmod +x reset-password.sh && ./reset-password.sh
docker compose up -d
```

---

## Whitelisting false positives

Add exceptions in AdGuard under **Filters → Custom filtering rules**:

```
@@||legitimate-domain.com^
```

Takes effect immediately — no restart needed.

---

## Troubleshooting

**NRD filter shows 0 rules.** Large filters load asynchronously — wait 90 seconds and refresh. Confirm the file exists: `ls -lh feed/output/nrd.adblock`.

**"API key file not readable."** Verify `/etc/whoisfreaks/apikey` exists on the host and the volume mount in `docker-compose.yml` points to it.

**Port 53 in use.** Run `sudo ss -tlnp | grep :53`. If `systemd-resolved` appears, follow Step 1 above.

**HTTP 401 on filter refresh.** `ADGUARD_PASS` in compose doesn't match the saved hash. Run `reset-password.sh` to resync.

---

## License

[MIT](LICENSE)

## Acknowledgments

- [WhoisFreaks](https://whoisfreaks.com/) for the NRD data feed
- [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) for the DNS filtering platform
- Palo Alto Networks Unit 42 for the research on NRD risk profiles
