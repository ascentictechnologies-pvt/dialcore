# DialCore — Ubuntu Server Deployment Guide

## Architecture

```
Internet  ──►  Nginx :443 / :80
               │
               ├──► /api/*          ──►  .NET 10 API      :5000  (systemd)
               ├──► /hubs/*         ──►  .NET 10 SignalR   :5000  (systemd)
               └──► Angular SPA         /opt/Ascentic/Dialer/ui   (static)

               Nginx :8089 (TLS terminator for SIP/WebSocket)
               └──► Asterisk PJSIP WS   :8090              (native systemd)

               SIP/RTP (direct)
               └──► Asterisk            :5060 / :10000-10100 (native systemd)

Local services (all native — no Docker)
  PostgreSQL 16 + TimescaleDB  :5432
  Redis 7                      :6379
  Coturn TURN                  :3478  (UDP/TCP)
  Asterisk 20                  :8088 (ARI) / :8090 (PJSIP WS) / :5060 (SIP)
```

---

## System Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU | 4 vCPU | 8 vCPU |
| RAM | 8 GB | 16 GB |
| Disk | 40 GB SSD | 100 GB SSD |
| Network | 100 Mbps | 1 Gbps |

---

## Required Open Ports (firewall/security-group)

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (redirects to 443) |
| 443 | TCP | HTTPS (UI + API) |
| 3478 | UDP+TCP | TURN/STUN (WebRTC) |
| 5060 | UDP+TCP | SIP signalling |
| 10000-10100 | UDP | RTP media |

Ports 5000, 5432, 6379, 8088, 8090 are **localhost-only** — do not expose externally.
Port 8089 (Nginx SIP/WSS) must be open if WebRTC browser phones are used.

---

## Software Versions

| Component | Version | Notes |
|---|---|---|
| .NET | 10.0 | Runtime + SDK |
| Node.js | 24 LTS | Angular build only |
| PostgreSQL | 16 | With TimescaleDB 2.x |
| TimescaleDB | 2.x | Community edition |
| Redis | 7.x | |
| Coturn | 4.6+ | |
| Nginx | 1.24+ | Reverse proxy + SIP/WSS terminator |
| Asterisk | 20 (Ubuntu 24.04 apt) | Native systemd service, no Docker |

---

## Quick Start (Automated)

**Domain:** `dialcore.ascentictechnologies.com`
**Let's Encrypt email:** `nageshsrivastava1988@gmail.com`

```bash
# 1. Ensure DNS A record points to server IP before running
#    dialcore.ascentictechnologies.com → <SERVER_IP>

# 2. Copy source to server
rsync -avz --exclude='.git' --exclude='*/bin' --exclude='*/obj' --exclude='*/node_modules' \
  ./ ubuntu@<SERVER_IP>:/opt/Ascentic/Dialer-src/

# 3. SSH into server
ssh ubuntu@<SERVER_IP>

# 4. Run pre-configured production deploy script
cd /opt/Ascentic/Dialer-src
sudo bash infra/scripts/deploy-production.sh

# For non-interactive mode (CI/CD):
sudo bash infra/scripts/deploy-production.sh -y
```

The script installs all dependencies, issues a Let's Encrypt TLS certificate, builds the app, configures all services, and starts everything. Credentials are saved to `/root/dialcore-credentials-<timestamp>.txt` — store them in a vault and delete the file.

> **Alternatively**, call the installer directly with full control over passwords:
> ```bash
> sudo bash infra/scripts/install.sh \
>   --domain dialcore.ascentictechnologies.com \
>   --certbot \
>   --letsencrypt-email nageshsrivastava1988@gmail.com \
>   --db-password     "YourStrongDBPass" \
>   --redis-password  "YourRedisPass" \
>   --jwt-secret      "YourMin32CharJwtSecretKeyHere!!"
> ```

---

## Manual Step-by-Step

### 1. System Update and Base Tools

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl wget gnupg2 ca-certificates lsb-release \
  apt-transport-https software-properties-common unzip git ffmpeg ufw
```

### 2. Asterisk (native)

```bash
sudo apt-get install -y asterisk

# Copy DialCore Asterisk config (from infra/asterisk/)
sudo cp infra/asterisk/*.conf /etc/asterisk/

# Set ARI password in ari.conf
sudo sed -i "s/^password = .*/password = <ARI_PASSWORD>/" /etc/asterisk/ari.conf

# Fix ownership
sudo chown -R asterisk:asterisk /etc/asterisk/ /var/spool/asterisk/ \
  /var/log/asterisk/ /var/lib/asterisk/

sudo systemctl enable --now asterisk
```

> Ubuntu 24.04 installs Asterisk 20 LTS. On 22.04 you get Asterisk 18 — both fully support ARI and PJSIP.

### 3. PostgreSQL 16 + TimescaleDB

```bash
# PostgreSQL official repo
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/postgresql.list

# TimescaleDB repo
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
  | sudo gpg --dearmor -o /etc/apt/keyrings/timescaledb.gpg
echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] \
  https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/timescaledb.list

sudo apt-get update
sudo apt-get install -y postgresql-16 timescaledb-2-postgresql-16

# Tune postgresql.conf for TimescaleDB
sudo timescaledb-tune --quiet --yes

sudo systemctl enable --now postgresql
```

Configure database:

```bash
DB_PASSWORD="change_me_strong_password"

sudo -u postgres psql <<SQL
CREATE USER dialcore WITH PASSWORD '${DB_PASSWORD}';
CREATE DATABASE dialcore OWNER dialcore;
\c dialcore
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
GRANT ALL PRIVILEGES ON DATABASE dialcore TO dialcore;
SQL
```

Edit `/etc/postgresql/16/main/pg_hba.conf` — add above `host all all 127.0.0.1/32 ident`:

```
host    dialcore        dialcore        127.0.0.1/32            scram-sha-256
host    dialcore        dialcore        ::1/128                 scram-sha-256
```

```bash
sudo systemctl reload postgresql
```

### 4. Redis 7

```bash
sudo apt-get install -y redis-server

# /etc/redis/redis.conf changes:
#   bind 127.0.0.1 ::1
#   requirepass <REDIS_PASSWORD>
#   maxmemory 512mb
#   maxmemory-policy allkeys-lru
sudo sed -i 's/^# requirepass .*/requirepass REDIS_PASS/' /etc/redis/redis.conf

sudo systemctl enable --now redis-server
```

### 5. Coturn (TURN/STUN)

```bash
sudo apt-get install -y coturn

# Enable daemon
sudo sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn

# /etc/turnserver.conf (relevant settings):
# listening-port=3478
# fingerprint
# lt-cred-mech
# realm=<YOUR_DOMAIN>
# user=dialcore:<COTURN_CREDENTIAL>
# total-quota=100
# bps-capacity=0
# stale-nonce=600

sudo systemctl enable --now coturn
```

### 6. .NET 10 SDK

```bash
# Microsoft package feed
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
OS_VER=$(lsb_release -rs)  # e.g. 22.04 or 24.04
echo "deb [signed-by=/etc/apt/keyrings/microsoft.gpg arch=amd64,arm64,armhf] \
  https://packages.microsoft.com/ubuntu/${OS_VER}/prod $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/microsoft-prod.list
sudo apt-get update
sudo apt-get install -y dotnet-sdk-10.0
```

### 7. Node.js 24

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### 8. Nginx

```bash
sudo apt-get install -y nginx
sudo systemctl enable nginx
```

### 9. Directory Structure

```bash
sudo useradd -r -s /sbin/nologin -m -d /opt/Ascentic/Dialer dialcore
sudo mkdir -p /opt/Ascentic/Dialer/{api,ui,recordings,logs}
sudo mkdir -p /etc/ascentic/dialer/ssl
sudo chown -R dialcore:dialcore /opt/Ascentic/Dialer /etc/ascentic/dialer
```

### 10. Build & Deploy API

```bash
cd /path/to/dialcore-source
dotnet publish src/DialCore.API/DialCore.API.csproj \
  -c Release -o /opt/Ascentic/Dialer/api \
  --no-self-contained \
  /p:UseAppHost=false
sudo chown -R dialcore:dialcore /opt/Ascentic/Dialer/api
```

### 11. Build & Deploy Angular UI

```bash
DOMAIN="your.domain.com"
API_URL="https://${DOMAIN}"

cat > src/dialcore-ui/src/environments/environment.prod.ts <<EOF
export const environment = {
  production: true,
  apiUrl: '${API_URL}/api',
  signalrUrl: '${API_URL}',
  sipServer: '${API_URL}',
  coturnUrl: 'turn:${DOMAIN}:3478',
  coturnUser: 'dialcore',
  coturnCredential: 'REPLACE_WITH_COTURN_CREDENTIAL'
};
EOF

cd src/dialcore-ui
npm ci --legacy-peer-deps
npm run build

sudo cp -r dist/dialcore-ui/browser/. /opt/Ascentic/Dialer/ui/
sudo chown -R dialcore:dialcore /opt/Ascentic/Dialer/ui
```

### 12. Production Configuration File

`install.sh` generates `/opt/Ascentic/Dialer/api/appsettings.Production.json` automatically with all secrets filled in. For a **manual** deploy, create it yourself:

```bash
# Generate secrets
DB_PASSWORD="your_strong_db_password"
REDIS_PASSWORD="your_redis_password"
ARI_PASSWORD="your_ari_password"
JWT_SECRET=$(openssl rand -hex 32)
SECRET_KEY=$(openssl rand -base64 32)   # save this — never change after first run
COTURN_CREDENTIAL="your_coturn_credential"
DOMAIN="dialcore.ascentictechnologies.com"

sudo tee /opt/Ascentic/Dialer/api/appsettings.Production.json > /dev/null <<EOF
{
  "Kestrel": {
    "Endpoints": {
      "UnixSocket": {
        "Url": "http://unix:/run/dialcore/api.sock"
      }
    }
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore": "Warning"
    }
  },
  "AllowedHosts": "*",
  "ConnectionStrings": {
    "Default": "Host=localhost;Port=5432;Database=dialcore;Username=dialcore;Password=${DB_PASSWORD};Maximum Pool Size=200;Minimum Pool Size=10;Connection Idle Lifetime=60;Command Timeout=30"
  },
  "DIALCORE_SECRET_KEY": "${SECRET_KEY}",
  "REDIS_CONNECTION": "localhost:6379,password=${REDIS_PASSWORD},abortConnect=false",
  "ASTERISK_ARI_URL": "http://localhost:8088",
  "ASTERISK_ARI_USER": "dialcore",
  "ASTERISK_ARI_PASSWORD": "${ARI_PASSWORD}",
  "ASTERISK_ARI_APP": "dialcore",
  "JWT_SECRET": "${JWT_SECRET}",
  "JWT_ISSUER": "dialcore",
  "JWT_AUDIENCE": "dialcore-api",
  "JWT_EXPIRY_MINUTES": "60",
  "CORS_ORIGINS": "https://${DOMAIN}",
  "RECORDING_STORAGE_TYPE": "local",
  "RECORDING_LOCAL_PATH": "/opt/Ascentic/Dialer/recordings",
  "COTURN_URL": "turn:${DOMAIN}:3478",
  "COTURN_USER": "dialcore",
  "COTURN_CREDENTIAL": "${COTURN_CREDENTIAL}",
  "LOG_FILE_PATH": "/opt/Ascentic/Dialer/logs/dialcore-",
  "LOG_FILE_MAX_SIZE_MB": "50",
  "LOG_FILE_RETAIN_DAYS": "30"
}
EOF
sudo chmod 640 /opt/Ascentic/Dialer/api/appsettings.Production.json
sudo chown root:dialcore /opt/Ascentic/Dialer/api/appsettings.Production.json
```

> **WARNING:** `DIALCORE_SECRET_KEY` encrypts DB columns at rest. Never change it after the first run — existing encrypted rows become permanently unreadable. Store it in a password vault.

> **Development:** `appsettings.json` provides dev defaults. The Unix socket binding only applies when `ASPNETCORE_ENVIRONMENT=Production` is set (i.e. the systemd service). `dotnet run` uses `:5000` by default.

### 13. Systemd Service

```bash
sudo tee /etc/systemd/system/dialcore-api.service > /dev/null <<EOF
[Unit]
Description=DialCore API
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=dialcore
Group=dialcore
WorkingDirectory=/opt/Ascentic/Dialer/api
ExecStart=/usr/bin/dotnet /opt/Ascentic/Dialer/api/DialCore.API.dll
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dialcore-api
EnvironmentFile=/etc/ascentic/dialer/dialcore.env
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/opt/Ascentic/Dialer/logs /opt/Ascentic/Dialer/recordings
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable dialcore-api
```

### 14. Nginx Configuration

```bash
sudo tee /etc/nginx/sites-available/dialcore.conf > /dev/null <<'NGINXEOF'
# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

# HTTPS main site
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate     /etc/ascentic/dialer/ssl/dialcore.crt;
    ssl_certificate_key /etc/ascentic/dialer/ssl/dialcore.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /opt/Ascentic/Dialer/ui;
    index index.html;

    add_header X-Frame-Options           "SAMEORIGIN"  always;
    add_header X-Content-Type-Options    "nosniff"     always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript application/wasm image/svg+xml font/woff2;

    location ~* \.(js|css|woff2?|ttf|eot|svg|png|ico|webp|wasm)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        expires 0;
    }

    location /api/ {
        proxy_pass         http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout  60s;
        proxy_connect_timeout 5s;
        proxy_send_timeout  60s;
        client_max_body_size 50m;
    }

    location /hubs/ {
        proxy_pass         http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        proxy_set_header   X-Real-IP  $remote_addr;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }

    location /health {
        proxy_pass http://127.0.0.1:5000;
        access_log off;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}

# Asterisk PJSIP SIP/WSS TLS terminator
# Browser WebRTC phones connect to wss://domain:8089
# Nginx terminates TLS, forwards plain WS to Asterisk PJSIP on :8090
server {
    listen 8089 ssl;
    server_name ${DOMAIN};
    ssl_certificate     /etc/ascentic/dialer/ssl/dialcore.crt;
    ssl_certificate_key /etc/ascentic/dialer/ssl/dialcore.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }
}
NGINXEOF

sudo sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/dialcore.conf
sudo ln -sf /etc/nginx/sites-available/dialcore.conf /etc/nginx/sites-enabled/dialcore.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

### 15. SSL Certificate

**Self-signed (testing):**
```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ascentic/dialer/ssl/dialcore.key \
  -out /etc/ascentic/dialer/ssl/dialcore.crt \
  -subj "/C=IN/ST=State/L=City/O=DialCore/CN=${DOMAIN}"
```

**Let's Encrypt (production — dialcore.ascentictechnologies.com):**
```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx \
  -d dialcore.ascentictechnologies.com \
  --non-interactive --agree-tos \
  -m nageshsrivastava1988@gmail.com

# Symlink certs into dialcore's expected path
sudo ln -sf /etc/letsencrypt/live/dialcore.ascentictechnologies.com/fullchain.pem \
            /etc/ascentic/dialer/ssl/dialcore.crt
sudo ln -sf /etc/letsencrypt/live/dialcore.ascentictechnologies.com/privkey.pem \
            /etc/ascentic/dialer/ssl/dialcore.key
```

### 16. Start All Services

```bash
sudo systemctl start postgresql redis-server coturn asterisk
sudo systemctl start dialcore-api
sudo nginx -t && sudo systemctl reload nginx
```

### 18. Firewall

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
sudo ufw allow 5060/udp
sudo ufw allow 5060/tcp
sudo ufw allow 10000:10100/udp
sudo ufw --force enable
```

---

## Service Management

```bash
# Status
sudo systemctl status dialcore-api asterisk postgresql redis-server coturn

# Logs
sudo journalctl -u dialcore-api -f
sudo journalctl -u asterisk -f
sudo tail -f /var/log/asterisk/messages
sudo tail -f /opt/Ascentic/Dialer/logs/dialcore-*.log

# Restart individual services
sudo systemctl restart dialcore-api
sudo systemctl restart asterisk
sudo systemctl restart postgresql

# Update API (rebuild and restart)
cd /path/to/source
dotnet publish src/DialCore.API/DialCore.API.csproj -c Release -o /opt/Ascentic/Dialer/api --no-self-contained /p:UseAppHost=false
sudo chown -R dialcore:dialcore /opt/Ascentic/Dialer/api
sudo systemctl restart dialcore-api

# Update Asterisk config (without full reinstall)
sudo cp infra/asterisk/*.conf /etc/asterisk/
sudo asterisk -rx "core reload"
```

---

## Health Checks

```bash
# API health
curl -sf http://localhost:5000/health

# PostgreSQL
sudo -u postgres psql -c "SELECT version();"

# Redis
redis-cli -a <REDIS_PASSWORD> ping

# Asterisk ARI
curl -u dialcore:<ASTERISK_PASSWORD> http://localhost:8088/ari/asterisk/info

# Coturn
turnutils_stunclient 127.0.0.1
```

---

## Backup

```bash
# Database
pg_dump -U dialcore -h localhost dialcore | gzip > /backup/dialcore-$(date +%Y%m%d).sql.gz

# Recordings
rsync -av /opt/Ascentic/Dialer/recordings/ /backup/recordings/

# Env and config
cp /etc/ascentic/dialer/dialcore.env /backup/dialcore.env
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| API not starting | `journalctl -u dialcore-api -n 50` — check DB connection string |
| 502 Bad Gateway | `systemctl status dialcore-api` — API may not be up |
| WebSocket disconnects | Check `/hubs/` nginx block timeout values |
| SIP registration fails | `sudo journalctl -u asterisk -n 50` — check pjsip.conf |
| TURN connection fails | `sudo ufw status` — ensure 3478 UDP is open |
| Migrations not applied | Check `journalctl -u dialcore-api` for EF migration errors |
| TimescaleDB missing | `psql -U dialcore -d dialcore -c "\dx"` — check extension |

---

## File Locations Summary

| Path | Purpose |
|---|---|
| `/opt/Ascentic/Dialer/api/` | .NET API binaries |
| `/opt/Ascentic/Dialer/ui/` | Angular static files |
| `/opt/Ascentic/Dialer/recordings/` | Call recordings |
| `/opt/Ascentic/Dialer/logs/` | Application logs |
| `/etc/ascentic/dialer/dialcore.env` | Runtime environment variables |
| `/etc/ascentic/dialer/ssl/` | SSL certificates |
| `/etc/systemd/system/dialcore-api.service` | Systemd unit |
| `/etc/nginx/sites-available/dialcore.conf` | Nginx site config |
| `/etc/postgresql/16/main/` | PostgreSQL config |
| `/etc/redis/redis.conf` | Redis config |
| `/etc/turnserver.conf` | Coturn config |
| `/etc/asterisk/` | Asterisk configuration (copied from `infra/asterisk/`) |
| `/var/log/asterisk/` | Asterisk logs |
