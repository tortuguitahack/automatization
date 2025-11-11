#!/usr/bin/env bash
# fix_apt_opera_duplicates.sh
# Repara problemas de apt: firmas faltantes (Opera), entradas duplicadas y warnings de traducciones.
# - Hace backups antes de tocar nada.
# - Añade keyring para Opera y actualiza línea del repo con signed-by si se detecta.
# - Elimina/komenta duplicados en /etc/apt/sources.list* conservando una copia.
# - Agrega config para desactivar traducciones y limpia caches.
#
# Ejecutar como root: sudo ./fix_apt_opera_duplicates.sh
set -euo pipefail
LOG="/var/log/fix_apt_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*"; }
err(){ echo -e "[ERROR] $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  err "Ejecuta este script con sudo/root."
fi

info "Inicio reparación apt - $(date)"
BACKUP_DIR="/root/apt_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
info "Creando backup de /etc/apt/* en $BACKUP_DIR"
cp -a /etc/apt/* "$BACKUP_DIR/"

# 1) Sanity: limpiar locks y procesos apt pendientes
info "Asegurando no haya procesos apt/dpkg en ejecución..."
if pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
  warn "Hay procesos apt/dpkg activos — espera a que terminen o matalos si estás seguro."
fi
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend || true

# 2) Detectar y normalizar duplicados en sources.list and sources.list.d
info "Detectando archivos de repos en /etc/apt/sources.list.d and /etc/apt/sources.list..."
SRC_FILES=(/etc/apt/sources.list)
for f in /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] && SRC_FILES+=("$f")
done

info "Creando versiones únicas por archivo (respaldo por archivo)."
for f in "${SRC_FILES[@]}"; do
  [ -f "$f" ] || continue
  cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
  # eliminar líneas vacías y comentarios para comparar; mantener una sola copia de cada linea activa
  awk '
    BEGIN{FS=OFS=""}
    /^[[:space:]]*#/ { print; next }
    /^[[:space:]]*$/ { next }
    { gsub(/[[:space:]]+$/,""); print }
  ' "$f" | awk '!seen[$0]++ { print }' > "$f.tmp"
  mv "$f.tmp" "$f"
  info "Procesado $f"
done

# 3) Opcional: Si hay múltiples archivos con la misma entrada (duplicación entre archivos),
#    intentar consolidar entradas idénticas en /etc/apt/sources.list.d/_consolidated.list
info "Consolidando entradas idénticas entre archivos a /etc/apt/sources.list.d/_consolidated.list (solo entradas activas)"
CONSOL="/etc/apt/sources.list.d/_consolidated.list"
> "$CONSOL"
declare -A seenline
for f in "${SRC_FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    # saltar comentarios y vacíos
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    # normalizar espacios multiples
    nline="$(echo "$line" | sed 's/[[:space:]]\\+/ /g' | sed 's/^[[:space:]]\\+//; s/[[:space:]]\\+$//')"
    if [ -z "${seenline[$nline]+x}" ]; then
      echo "$nline" >> "$CONSOL"
      seenline[$nline]=1
    fi
  done < "$f"
done

# Ahora reemplazamos: dejar consolidado y comentar las entradas originales (para seguridad)
info "Comentando entradas idénticas en archivos originales (se conservarán como backup)."
for f in "${SRC_FILES[@]}"; do
  [ -f "$f" ] || continue
  # comentar líneas que estén en consolidated (pero conservamos archivo como respaldo)
  awk -v CONS="$CONSOL" '
    BEGIN {
      while((getline c < CONS) > 0) { cons[c]=1 }
      close(CONS)
    }
    {
      line=$0
      # ignore comment lines
      if (line ~ /^[[:space:]]*#/) { print line; next }
      # normalize
      n=line
      gsub(/[[:space:]]+/, " ", n)
      sub(/^[[:space:]]+/, "", n)
      sub(/[[:space:]]+$/, "", n)
      if (n in cons) {
        print "# DUP_CONSOLIDATED " line
      } else {
        print line
      }
    }
  ' "$f" > "$f.new"
  mv "$f.new" "$f"
done

# Put consolidated file in place (only if not empty)
if [ -s "$CONSOL" ]; then
  info "Colocando $CONSOL como fuente única consolidada (si quieres revertir, encuentra backups en $BACKUP_DIR)."
  chmod 644 "$CONSOL"
else
  warn "$CONSOL está vacío; no se modificó."
fi

# 4) Desactivar descarga de traducciones (reduce mensajes warnings y tiempo)
APT_CONF="/etc/apt/apt.conf.d/99no-translations"
if [ ! -f "$APT_CONF" ]; then
  info "Agregando /etc/apt/apt.conf.d/99no-translations para desactivar traducciones APT"
  cat > "$APT_CONF" <<'EOF'
# Disable downloading translations to avoid repeated translation warnings and speed up apt update
Acquire::Languages "none";
EOF
else
  info "$APT_CONF ya existe, se conserva."
fi

# 5) Intentar reparar repo Opera: si existe entrada a deb.opera.com tratamos de añadir keyring y signed-by
info "Buscando entradas Opera en los sources..."
OPERA_LINES=$(grep -RIn "deb.*opera.*deb.opera.com\|deb.*opera.*opera-stable" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)
if [ -n "$OPERA_LINES" ]; then
  info "Entradas Opera detectadas:"
  echo "$OPERA_LINES" | tee -a "$LOG"
  # descargar key y guardarla en keyring
  KEYRING="/usr/share/keyrings/opera-archive-keyring.gpg"
  info "Descargando clave oficial de Opera y guardando en $KEYRING"
  # método robusto: intentar https://deb.opera.com/archive.key
  if curl -fsSL "https://deb.opera.com/archive.key" -o "$KEYRING.tmp"; then
    # convert to gpg format if necessary
    gpg --dearmor "$KEYRING.tmp" 2>/dev/null || true
    # Some distros expect .gpg binary; use gpg --dearmor to convert, fallback to mv
    if gpg --dearmor "$KEYRING.tmp" >/dev/null 2>&1; then
      gpg --dearmor "$KEYRING.tmp" > "$KEYRING" 2>/dev/null || cp -f "$KEYRING.tmp" "$KEYRING"
    else
      cp -f "$KEYRING.tmp" "$KEYRING"
    fi
    rm -f "$KEYRING.tmp"
    chmod 644 "$KEYRING"
    info "Key stored at $KEYRING"
    # Update each file that contains opera to include signed-by if not present
    info "Actualizando líneas de repos que contienen 'opera' para usar 'signed-by=$KEYRING' (se hace backup por archivo)"
    while IFS= read -r match; do
      file=$(echo "$match" | cut -d: -f1)
      # backup already created
      info "Procesando $file"
      # replace occurrences of 'deb https://deb.opera.com/...' adding signed-by if not already present
      sed -E -i.bak -e "s#(deb\\s+\\[?)([^\\]]*\\]?\\s*)(https?://deb.opera.com[^[:space:]]*)(.*)#\\1signed-by=${KEYRING} \\2\\3 \\4#g" "$file" || true
      # if sed didn't add (different formatting), attempt a safer in-place insertion for lines with opera
      awk -v key="$KEYRING" '
        BEGIN{OFMT="%.0f"}
        { if(match($0, /deb.*(opera|deb.opera.com)/i)) {
            if(index($0,"signed-by") == 0) {
              # insert signed-by after "deb "
              sub(/^deb[[:space:]]+/,"deb [signed-by=" key "] ")
              print
            } else { print }
          } else { print }
        }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    done < <(grep -RIn "deb.*opera" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | cut -d: -f1 | sort -u)
  else
    warn "No se pudo descargar la clave oficial de Opera automáticamente. Se comentarán las entradas Opera para evitar fallos en apt."
    # comentar entradas Opera
    grep -RIn "deb.*opera" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | cut -d: -f1 | sort -u | while read -r f; do
      cp -a "$f" "$f.opera_disabled.bak"
      sed -E -i 's/^(.*(opera|deb.opera.com).*)$/# OPERA_DISABLED \1/g' "$f" || true
      info "Comentada entradas Opera en $f (copia en $f.opera_disabled.bak)"
    done
  fi
else
  info "No se detectaron entradas Opera en fuentes APT."
fi

# 6) Limpieza y reparación de apt/dpkg
info "Limpiando listas APT y reparando dpkg/apt..."
rm -rf /var/lib/apt/lists/* || true
apt-get clean -y || true
apt-get update --allow-insecure-repositories || true || true
# try dpkg configure and fix broken packages
dpkg --configure -a || true
apt-get -f install -y || true

# 7) Ejecutar apt update y apt upgrade final
info "Ejecutando apt update y apt upgrade..."
if apt-get update -o Acquire::Languages=none; then
  info "apt update OK"
else
  warn "apt update falló (siguiendo con intentos de diagnostico). Se mostrará salida de apt update a continuación."
  apt-get update -o Acquire::Languages=none || true
fi

info "Intentando apt upgrade - revisa salida y confirma si quieres ejecutar apt full-upgrade"
apt-get upgrade -y || warn "apt upgrade tuvo fallos; revisa salida."

# 8) Recomendaciones post-fix
echo
info "Hecho. Recomendaciones:"
cat <<EOF
- Revisa $LOG y revisa los backups en $BACKUP_DIR si algo no queda bien.
- Si quieres reinstaurar un archivo original:
    cp -a $BACKUP_DIR/<nombre>.bak /etc/apt/sources.list.d/<nombre>.list
- Si dejé las entradas Opera comentadas, y quieres re-habilitarlas con la key:
    1) Asegúrate que /usr/share/keyrings/opera-archive-keyring.gpg exista.
    2) Edita el archivo .list correspondiente y elimina la almohadilla '#' delante de las líneas OPERA_DISABLED o reemplaza la línea con:
       deb [arch=amd64 signed-by=/usr/share/keyrings/opera-archive-keyring.gpg] https://deb.opera.com/opera-stable stable non-free
- Para reducir aún más warnings y acelerar apt, mantener /etc/apt/apt.conf.d/99no-translations existe y está activo.
- Si aún ves advertencias de duplicados, revisa manualmente los .list en /etc/apt/sources.list.d/ para entradas muy particulares (p. ej. PPAs o repos 3ros duplicados).
EOF

info "Fin: $(date). Log guardado en $LOG"