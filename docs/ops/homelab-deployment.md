# Homelab Deployment Guide (Proxmox LXC + Cloudflare + WhatsApp)

This guide provides a complete path from source to production in a Proxmox homelab.

## 1. Prerequisites
- Proxmox VE, with LXC support
- Cloudflare account (with Tunnel capability)
- WhatsApp Business API credentials (`phone_number_id`, `access_token`, `app_secret`)
- GitHub repository with secrets configured

## 1.1 Optional helper script
A helper script is included in `scripts/deploy/lxc-deploy.sh` to bootstrap a container and start ZeroClaw.

```bash
bash scripts/deploy/lxc-deploy.sh 100
```

## 2. LXC setup (Debian 13 / Ubuntu 24)

1. Create container:
   ```bash
   pct create 100 local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst \
     --hostname zeroclaw-agent --cores 2 --memory 4096 --swap 1024 --rootfs local-lvm:32 \
     --net0 name=eth0,bridge=vmbr0,ip=192.168.1.20/24,gw=192.168.1.1
   pct start 100
   pct exec 100 -- bash -lc "apt update && apt install -y curl git build-essential pkg-config libssl-dev cmake llvm libclang-dev"
   ```

2. Install Rust in container:
   ```bash
   pct exec 100 -- bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; source /root/.cargo/env"
   ```

3. Clone and build:
   ```bash
   pct exec 100 -- bash -lc "git clone https://github.com/YOUR-USERNAME/zeroclaw.git /opt/zeroclaw && cd /opt/zeroclaw && cargo build --release"
   ```

## 3. Systemd service template

`/etc/systemd/system/zeroclaw.service`

```ini
[Unit]
Description=ZeroClaw agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/zeroclaw
ExecStart=/opt/zeroclaw/target/release/zeroclaw run --config /opt/zeroclaw/config.toml
Restart=on-failure
RestartSec=5
Environment="RUST_LOG=info"

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
pct exec 100 -- systemctl daemon-reload
pct exec 100 -- systemctl enable --now zeroclaw
```

## 4. Cloudflare Tunnel

1. Install `cloudflared` and login.
2. Create tunnel:
   ```bash
   pct exec 100 -- cloudflared tunnel create zeroclaw
   ```
3. Configure route (example):
   ```yaml
   tunnel: <TUNNEL-ID>
   credentials-file: /etc/cloudflared/<tunnel>.json

   ingress:
     - hostname: zeroclaw.example.com
       service: http://127.0.0.1:8080
     - service: http_status:404
   ```
4. Run tunnel as service and verify.

## 5. WhatsApp channel configuration (Gateway Webhook mode)

`config.toml`:

```toml
[channels_config.whatsapp]
access_token = "EAAB..."
phone_number_id = "123456789012345"
verify_token = "your-verify-token"
app_secret = "your-app-secret"
allowed_numbers = ["*"]
```

`[gateway_config]` should have host/port defaults that match the tunnel target (e.g., 8080).

## 6. GitHub Actions auto-deploy

Use `.github/workflows/homelab-deploy.yml`.

### Required repo secrets:
- `HOMELAB_SSH_HOST`
- `HOMELAB_SSH_USER`
- `HOMELAB_SSH_PORT` (optional, default 22)
- `HOMELAB_SSH_KEY` (private key)

## 7. Health + smoke tests
- `curl -k https://zeroclaw.example.com/health`
- WhatsApp webhook verification from Meta Cloud API
- `systemctl status zeroclaw` in LXC

## 8. Rollback
- `git checkout <previous-tag>` + `cargo build --release`
- Re-run deploy job with ref
