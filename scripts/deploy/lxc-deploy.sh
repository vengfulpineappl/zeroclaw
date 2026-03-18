#!/usr/bin/env bash
set -euo pipefail

LXC_ID=${1:-100}
TEMPLATE=${2:-ubuntu-24.04-standard_24.04-1_amd64.tar.zst}
HOSTNAME=${3:-zeroclaw-agent}
IP=${4:-192.168.1.50/24}
GATEWAY=${5:-192.168.1.1}

if ! command -v pct >/dev/null 2>&1; then
  echo "pct command not found; run on Proxmox host with LXC support" >&2
  exit 1
fi

echo "Creating LXC container $LXC_ID"
pct create "$LXC_ID" local:vztmpl/$TEMPLATE \
  --hostname "$HOSTNAME" --cores 2 --memory 4096 --swap 1024 --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY

pct start "$LXC_ID"

echo "Installing dependencies"
pct exec "$LXC_ID" -- bash -lc "apt-get update -qq && apt-get install -y curl git build-essential pkg-config libssl-dev cmake llvm libclang-dev"

echo "Installing Rust"
pct exec "$LXC_ID" -- bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source /root/.cargo/env"

echo "Installing cloudflared"
pct exec "$LXC_ID" -- bash -lc "curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb && apt-get update -qq && apt-get install -y /tmp/cloudflared.deb"

cat <<'EOF' >/tmp/cloudflared.yml
url: http://127.0.0.1:8080
hostname: zeroclaw.example.com
logfile: /var/log/cloudflared.log
loglevel: info
EOF

pct exec "$LXC_ID" -- bash -lc "mkdir -p /etc/cloudflared && mv /tmp/cloudflared.yml /etc/cloudflared/config.yml && cloudflared service install || true"

echo "Cloning repo and building ZeroClaw"
pct exec "$LXC_ID" -- bash -lc "rm -rf /opt/zeroclaw && git clone https://github.com/YOUR-USERNAME/zeroclaw.git /opt/zeroclaw && cd /opt/zeroclaw && /root/.cargo/bin/cargo build --release"

cat <<'EOF' >/tmp/zeroclaw.service
[Unit]
Description=ZeroClaw LXC Agent
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
EOF

echo "Writing systemd service"
pct push "$LXC_ID" /tmp/zeroclaw.service /etc/systemd/system/zeroclaw.service

echo "Enabling and starting ZeroClaw service"
pct exec "$LXC_ID" -- bash -lc "systemctl daemon-reload && systemctl enable --now zeroclaw"

echo "Deployment complete. Check:
  pct exec $LXC_ID -- systemctl status zeroclaw
  pct exec $LXC_ID -- journalctl -u zeroclaw -n 50 --no-pager
"
