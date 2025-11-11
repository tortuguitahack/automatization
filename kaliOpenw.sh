#!/usr/bin/env bash

kali_openwebui_ollama_traefik_compose.sh

Deploys Dockerized Ollama + Open-WebUI behind Traefik with basic auth + ACME placeholders

Designed to run on Kali (or Debian-based) host where Docker is already installed.

Usage: edit DOMAIN and EMAIL below, then run as root: sudo bash ./kali_openwebui_ollama_traefik_compose.sh

set -euo pipefail SCRIPT_LOG="/var/log/kali_openwebui_install.log" exec > >(tee -a "$SCRIPT_LOG") 2>&1

--- CONFIGURATION (EDIT BEFORE RUNNING) ---

DOMAIN="example.com"        # <- REPLACE with your domain pointing to this host EMAIL="me@example.com"      # <- REPLACE for Let's Encrypt registration OAUTH_USER="admin"          # basic auth user for WebUI OAUTH_PASS="changeme"       # basic auth password (will be hashed) STACK_DIR="/opt/ai-lab/openwebui-ollama" OLLAMA_IMAGE="ollama/ollama:latest" OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:main" TRAEFIK_IMAGE="traefik:v3"

Safety check

if [ "$DOMAIN" = "example.com" ]; then echo "[WARN] DOMAIN is still 'example.com'. Edit the script and set DOMAIN to your real domain before proceeding." >&2 read -p "Proceed anyway? (y/N): " yn if [[ "$yn" != "y" && "$yn" != "Y" ]]; then echo "Aborting."; exit 1 fi fi

mkdir -p "$STACK_DIR" cd "$STACK_DIR"

Install apache2-utils for htpasswd if not present

if ! command -v htpasswd >/dev/null 2>&1; then apt update -y apt install -y apache2-utils fi

Create htpasswd file

HTPASSWD_FILE="$STACK_DIR/.htpasswd" htpasswd -Bbc "$HTPASSWD_FILE" "$OAUTH_USER" "$OAUTH_PASS" chmod 640 "$HTPASSWD_FILE"

Create Traefik dynamic config for basic auth middleware

cat > "$STACK_DIR/traefik_dynamic.yml" <<'YAML' http: middlewares: auth: basicAuth: usersFile: /traefik/htpasswd YAML

Create traefik static config

cat > "$STACK_DIR/traefik.yml" <<'YAML' api: dashboard: true entryPoints: web: address: ":80" websecure: address: ":443" providers: docker: {} certificatesResolvers: le: acme: email: "$EMAIL" storage: /letsencrypt/acme.json tlsChallenge: {} YAML

Create Docker Compose file

cat > "$STACK_DIR/docker-compose.yml" <<'YAML' version: '3.9' services: traefik: image: $TRAEFIK_IMAGE command: - --configFile=/etc/traefik/traefik.yml ports: - "80:80" - "443:443" volumes: - ./traefik.yml:/etc/traefik/traefik.yml:ro - ./traefik_dynamic.yml:/etc/traefik/traefik_dynamic.yml:ro - ./acme:/letsencrypt - $STACK_DIR/.htpasswd:/traefik/htpasswd:ro - /var/run/docker.sock:/var/run/docker.sock:ro restart: unless-stopped

ollama: image: $OLLAMA_IMAGE restart: unless-stopped volumes: - ollama_data:/root/.ollama ports: - "11434:11434" # Ollama API default labels: - "traefik.enable=true" - "traefik.http.routers.ollama.rule=Host(ollama.$DOMAIN)" - "traefik.http.routers.ollama.entrypoints=websecure" - "traefik.http.routers.ollama.tls.certresolver=le" - "traefik.http.routers.ollama.middlewares=auth@file"

openwebui: image: $OPENWEBUI_IMAGE restart: unless-stopped environment: - OLLAMA_URL=http://ollama:11434 ports: - "3000:3000" labels: - "traefik.enable=true" - "traefik.http.routers.openwebui.rule=Host($DOMAIN)" - "traefik.http.routers.openwebui.entrypoints=websecure" - "traefik.http.routers.openwebui.tls.certresolver=le" - "traefik.http.routers.openwebui.middlewares=auth@file" depends_on: - ollama

volumes: ollama_data: YAML

Ensure permissions

chown -R root:root "$STACK_DIR" chmod -R 750 "$STACK_DIR"

Create acme storage

mkdir -p "$STACK_DIR/acme" chmod 600 "$STACK_DIR/acme"

Create systemd service to run docker compose

cat > /etc/systemd/system/openwebui-ollama.service <<'UNIT' [Unit] Description=OpenWebUI + Ollama Stack Requires=docker.service After=docker.service

[Service] Type=oneshot RemainAfterExit=yes WorkingDirectory=$STACK_DIR ExecStart=/usr/bin/docker compose up -d ExecStop=/usr/bin/docker compose down

[Install] WantedBy=multi-user.target UNIT

systemctl daemon-reload systemctl enable --now openwebui-ollama.service || true

echo "Deployment finished. Visit https://$DOMAIN (OpenWebUI) and https://ollama.$DOMAIN (Ollama API)." echo "If Let's Encrypt fails (rate limits or DNS not set), Traefik will not obtain certs. Set DOMAIN properly and ensure ports 80/443 reachable."

exit 0