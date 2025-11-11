#!/usr/bin/env bash
# Solución avanzada definitiva para el error de firma del repositorio Opera en Kali / Debian
# Limpia restos antiguos, instala la clave oficial y reconfigura la fuente.
set -euo pipefail

echo "[INFO] --- Iniciando reparación avanzada del repositorio de Opera ---"
BACKUP_DIR="/root/backup_opera_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 1. Respaldo de archivos
echo "[INFO] Creando backup de fuentes APT en $BACKUP_DIR"
cp -a /etc/apt/sources.list* "$BACKUP_DIR/" 2>/dev/null || true

# 2. Eliminar entradas Opera obsoletas o con HTTP inseguro
echo "[INFO] Limpiando entradas antiguas de Opera..."
grep -Rl "opera" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
    sed -i '/opera/d' "$f"
done

# 3. Crear nuevo keyring limpio
echo "[INFO] Descargando y registrando clave oficial de Opera..."
mkdir -p /usr/share/keyrings/
curl -fsSL https://deb.opera.com/archive.key | gpg --dearmor -o /usr/share/keyrings/opera-archive-keyring.gpg

# 4. Añadir nuevo repositorio seguro HTTPS con firma validada
echo "[INFO] Agregando repositorio Opera estable con firma verificada..."
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/opera-archive-keyring.gpg] https://deb.opera.com/opera