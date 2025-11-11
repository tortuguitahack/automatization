#!/usr/bin/env bash
# kali_ai_redteam_base.sh
# Preparación y hardening de Kali Linux orientado a Red-Team ético + IA local (Ollama, LLM runtimes)
# NOTA: No instala herramientas ofensivas. Ejecutar como root.
set -euo pipefail
LOG="/var/log/kali_ai_base_install.log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*"; }
err(){ echo -e "[ERROR] $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  err "Ejecuta este script con sudo o como root."
fi

info "Inicio $(date)"

# 1) Actualizar sistema
info "Actualizando paquetes APT..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y

# 2) Paquetes base y utilidades
info "Instalando utilidades base..."
apt install -y --no-install-recommends \
  curl wget git htop jq unzip build-essential ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https sudo lsof net-tools iproute2

# 3) ZRAM (mejora rendimiento en swap)
info "Configurando zram..."
apt install -y zram-tools || warn "zram-tools no disponible, continuando..."
cat >/etc/default/zramswap <<'EOF'
ALGO=lz4
PCT=40
EOF
systemctl enable --now zramswap.service || true

# 4) sysctl tuning (IO, redes, límites)
info "Aplicando ajustes sysctl..."
cat >/etc/sysctl.d/99-kali-ai.conf <<'EOF'
# Kali AI / Red-Team research tuning
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.file-max=2097152
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
EOF
sysctl --system || true

# 5) Ajustes limits.conf para procesos intensivos
info "Ajustando límites de usuario (nofile, nproc)..."
cat >/etc/security/limits.d/99-kali-ai.conf <<'EOF'
* soft nofile 524288
* hard nofile 524288
* soft nproc 65536
* hard nproc 65536
EOF

# 6) Swapfile fallback (si no hay swap)
if ! swapon --show | grep -q '^'; then
  warn "No se detectó swap activo. Creando /swapfile 8G..."
  fallocate -l 8G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 7) Kernel low-latency (opcional)
info "Intentando instalar kernel low-latency (si está en repos)..."
apt install -y linux-lowlatency || warn "linux-lowlatency no disponible; omitiendo."

# 8) Detectar GPU NVIDIA y proponer drivers
detect_nvidia(){
  if command -v nvidia-smi >/dev/null 2>&1; then echo "present"; return; fi
  if lspci | grep -i nvidia >/dev/null 2>&1; then echo "detected"; return; fi
  echo "none"
}
GPU_STATE="$(detect_nvidia)"
if [ "$GPU_STATE" != "none" ]; then
  info "NVIDIA GPU detectada: procediendo a instalar drivers recomendados..."
  ubuntu_drivers_available=false
  if command -v ubuntu-drivers >/dev/null 2>&1; then
    ubuntu_drivers_available=true
  fi
  if $ubuntu_drivers_available; then
    ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall falló"
  else
    warn "No hay ubuntu-drivers util; recomendamos instalar drivers oficiales NVIDIA/CUDA manualmente."
  fi
fi

# 9) Docker & Compose (para contenerizar runtimes)
info "Instalando Docker y docker compose plugin..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
ARCH=$(dpkg --print-architecture)
echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || warn "Instalación Docker tiene advertencias"
# permitir uso de docker al usuario habitual si existe
if [ -n "${SUDO_USER:-}" ]; then
  usermod -aG docker "$SUDO_USER" || true
fi

# 10) Podman (opcional)
info "Instalando podman (opcional)..."
apt install -y podman || true

# 11) Python / venv / pip e instalación de libs IA
info "Instalando Python3, venv y dependencias IA (CPU fallback seguro)..."
apt install -y python3 python3-venv python3-dev python3-pip build-essential cmake libopenblas-dev || true
python3 -m pip install --upgrade pip setuptools wheel
mkdir -p /opt/ai-lab
python3 -m venv /opt/ai-lab/venv
source /opt/ai-lab/venv/bin/activate
pip install --upgrade pip
pip install langchain==0.0.### transformers sentence-transformers accelerate || true
# torch: prefer wheel that fits system; try CPU fallback to avoid GPU mismatch
pip install torch --index-url https://download.pytorch.org/whl/cpu || true
pip install sentence-transformers fastapi uvicorn[standard] gpt4all faster-whisper whisperx || true

# 12) llama.cpp skeleton (compilación básica, útil para ggml/quant)
info "Clonando y compilando llama.cpp (si no existe)..."
if [ ! -d /opt/llama.cpp ]; then
  git clone https://github.com/ggerganov/llama.cpp.git /opt/llama.cpp || true
  cd /opt/llama.cpp || true
  make || true
fi

# 13) Ollama: instalación desde instalador oficial (script remoto) - ver fuente oficial
info "Instalando Ollama (instalador oficial)..."
# Fuente oficial: https://ollama.com/download/linux (instalador curl | sh)
curl -fsSL https://ollama.com/install.sh | sh || warn "Instalación Ollama terminó con advertencias. Revisa $LOG y 'ollama --version'"

# 14) Crear directorios para modelos y datos
info "Creando directorios /opt/models y /opt/ai-lab/data..."
mkdir -p /opt/models /opt/ai-lab/data
chown -R root:root /opt/models /opt/ai-lab
chmod -R 750 /opt/models

# 15) Weaviate vector DB opcional por Docker (contenedor) — útil para RAG/embeddings
info "Desplegando Weaviate (opcional) en Docker Compose (si docker funciona)..."
cat >/opt/ai-lab/weaviate-docker-compose.yml <<'YAML'
version: '3.8'
services:
  weaviate:
    image: semitechnologies/weaviate:latest
    ports:
      - "8080:8080"
    environment:
      - QUERY_DEFAULTS_LIMIT=20
      - AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=true
      - PERSISTENCE_DATA_PATH=/var/lib/weaviate
    volumes:
      - weaviate_data:/var/lib/weaviate
volumes:
  weaviate_data:
YAML
# start it but don't fail hard if docker isn't fully ready
if command -v docker >/dev/null 2>&1; then
  docker compose -f /opt/ai-lab/weaviate-docker-compose.yml up -d || warn "Weaviate docker compose fallo o ya levantado"
fi

# 16) Hardening: UFW, fail2ban, auditd, apparmor, AIDE
info "Configurando UFW, Fail2Ban, auditd, AppArmor y AIDE..."
apt install -y ufw fail2ban auditd apparmor apparmor-utils aide logrotate || true
ufw default deny incoming
ufw default allow outgoing
# permitir SSH, Ollama (por defecto escucha en 11434 http API), y servicios locales (modifica si expones)
ufw allow 22/tcp
ufw allow 11434/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || warn "UFW pudo fallar; revisa estado"
cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
EOF
systemctl enable --now fail2ban || true
# AIDE init
aideinit || true
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db || true

# 17) Auditd rules basic
cat >/etc/audit/rules.d/99-kali-ai.rules <<'EOF'
# Audit critical file access
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/sudoers -p wa -k sudoers_changes
EOF
systemctl restart auditd || true

# 18) Systemd timer for daily maintenance (apt update/clean/docker prune)
info "Creando tarea systemd para mantenimiento diario..."
cat >/usr/local/bin/kali_ai_maintenance.sh <<'MAINT'
#!/usr/bin/env bash
set -e
apt update -y && apt upgrade -y
apt autoremove -y
docker system prune -af || true
journalctl --vacuum-time=7d || true
MAINT
chmod +x /usr/local/bin/kali_ai_maintenance.sh

cat >/etc/systemd/system/kali-ai-maint.service <<'UNIT'
[Unit]
Description=Kali AI maintenance tasks
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kali_ai_maintenance.sh
[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/kali-ai-maint.timer <<'TIMER'
[Unit]
Description=Daily Kali AI maintenance
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now kali-ai-maint.timer || true

# 19) Create README with next steps and safety
info "Escribiendo /opt/ai-lab/README.txt..."
cat >/opt/ai-lab/README.txt <<'EOF'
Kali AI & RedTeam Base Readme
- Ollama installed via official installer (https://ollama.com). Verify: `ollama --version`
- Models: place model files under /opt/models and adjust olm/ollama config if needed.
- Docker services (Weaviate) at /opt/ai-lab/weaviate-docker-compose.yml
- Python venv at /opt/ai-lab/venv -> activate with: source /opt/ai-lab/venv/bin/activate
- Important: this machine is hardened but still should be run in an isolated lab network when doing pentesting.
- To enable/disable Ollama service: follow Ollama docs; alternatively run `ollama daemon` as needed.
EOF
chmod 640 /opt/ai-lab/README.txt

info "Instalación básica completada. Recomendado: reboot ahora para aplicar kernels/drivers."
info "Logs en: $LOG"
echo "Script finalizado: $(date)"
exit 0