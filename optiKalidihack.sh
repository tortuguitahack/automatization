#!/usr/bin/env bash
# kali_deep_clean_keep_ms_burp.sh
# Deep-clean de Kali Linux: deja sólo Metasploit y BurpSuite Pro (intentos de detección)
# Modo por defecto: DRY-RUN. Añadir --yes ejecuta las acciones peligrosas.
#
# Uso:
#   ./kali_deep_clean_keep_ms_burp.sh        # dry-run
#   ./kali_deep_clean_keep_ms_burp.sh --yes  # aplica cambios
#
set -euo pipefail
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="/var/log/kali_deep_clean_${TIMESTAMP}.log"
BACKUP_DIR="/root/kali_clean_backup_${TIMESTAMP}"
DRY_RUN=true
FORCE_NO_PROMPT=false

# PACKAGES / PATHS TO KEEP (adjust if your Burp/Metasploit installed in custom paths)
KEEP_PACKAGES=(metasploit-framework)   # package names to preserve if installed via apt
# burpsuite is often not a package; we preserve common installation paths below
KEEP_PATHS=( \
  "/opt/burpsuite*" \
  "/usr/local/bin/burpsuite*" \
  "/usr/bin/burpsuite*" \
  "/home/*/burpsuite*" \
  "/opt/metasploit*" \
  "/usr/share/metasploit-framework" \
  "/usr/local/share/metasploit-framework" \
)

# Directories to consider clearing except KEEP_PATHS
CLEAN_DIRS=(/opt /usr/local /usr/share/applications /var/lib /srv /home)

# Safety: essential packages that must never be removed (will be auto-detected + added)
ESSENTIAL_PACKAGES_MIN=(base-files bash coreutils dpkg apt systemd login passwd util-linux) 

# Parse args
for arg in "$@"; do
  case "$arg" in
    --yes) DRY_RUN=false ;;
    --no-prompt) FORCE_NO_PROMPT=true ;;
    --help) echo "Usage: $0 [--yes]"; exit 0 ;;
    *) echo "[WARN] Unknown arg: $arg";;
  esac
done

# Logging
exec > >(tee -a "$LOG") 2>&1
echo "=== Kali deep clean started at $(date) ==="

# ensure root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Ejecuta como root (sudo)." >&2
  exit 1
fi

# Create backup dir
mkdir -p "$BACKUP_DIR"
echo "[INFO] Backup dir: $BACKUP_DIR"

# 1) Backup important files and lists
echo "[STEP 1] Backups: apt sources, installed packages list, /opt snapshot (metadata only)."
cp -a /etc/apt/sources.list* "$BACKUP_DIR/" || true
dpkg --get-selections > "$BACKUP_DIR/dpkg_selections_${TIMESTAMP}.txt"
apt-mark showmanual > "$BACKUP_DIR/apt_manual_${TIMESTAMP}.txt"
tar -czf "$BACKUP_DIR/opt_snapshot_${TIMESTAMP}.tgz" --warning=no-file-changed --exclude='*.cache' /opt || true
tar -czf "$BACKUP_DIR/usr_local_snapshot_${TIMESTAMP}.tgz" --warning=no-file-changed --exclude='*.cache' /usr/local || true
cp -a /etc/fstab "$BACKUP_DIR/" || true
echo "[INFO] Backups created."

# 2) Detect system essential packages automatically
echo "[STEP 2] Detectando paquetes esenciales del sistema..."
# Packages with priority required, important, standard
dpkg-query -W -f='${Package} ${Priority}\n' | awk '$2=="required"||$2=="important"||$2=="standard"{print $1}' | sort -u > "$BACKUP_DIR/essential_pkgs.txt"
# augment with our minimal list
for p in "${ESSENTIAL_PACKAGES_MIN[@]}"; do echo "$p"; done >> "$BACKUP_DIR/essential_pkgs.txt"
sort -u -o "$BACKUP_DIR/essential_pkgs.txt" "$BACKUP_DIR/essential_pkgs.txt"
ESSENTIAL_PKGS=($(cat "$BACKUP_DIR/essential_pkgs.txt"))

echo "[INFO] Essential pkgs count: ${#ESSENTIAL_PKGS[@]}"

# 3) Build candidate removal list: manual packages minus essential minus keep packages
echo "[STEP 3] Construyendo lista de paquetes manuales a evaluar para purgar..."
mapfile -t MANUAL_PKGS < <(apt-mark showmanual | sort -u)
# remove essential and keep packages from this list
declare -A to_keep_map=()
for p in "${ESSENTIAL_PKGS[@]}"; do to_keep_map["$p"]=1; done
for p in "${KEEP_PACKAGES[@]}"; do to_keep_map["$p"]=1; done

CANDIDATES=()
for p in "${MANUAL_PKGS[@]}"; do
  if [ -n "${to_keep_map[$p]:-}" ]; then
    # keep
    continue
  fi
  # skip meta packages like task-*
  if [[ "$p" =~ ^task- ]]; then continue; fi
  CANDIDATES+=("$p")
done

echo "[INFO] Manual packages total: ${#MANUAL_PKGS[@]}, candidates for removal: ${#CANDIDATES[@]}"

# 4) Detect installed files/paths for burp/metasploit and mark additional paths to keep
echo "[STEP 4] Buscando rutas de BurpSuite y Metasploit instaladas fuera de apt..."
EXTRA_KEEP_PATHS=()
# search common burp locations
for pattern in "${KEEP_PATHS[@]}"; do
  matches=( $(ls -d $pattern 2>/dev/null || true) )
  for m in "${matches[@]}"; do
    if [ -e "$m" ]; then
      EXTRA_KEEP_PATHS+=("$m")
    fi
  done
done

if [ ${#EXTRA_KEEP_PATHS[@]} -gt 0 ]; then
  echo "[INFO] Se detectaron rutas a preservar:"
  for p in "${EXTRA_KEEP_PATHS[@]}"; do echo "  - $p"; done
else
  echo "[WARN] No se detectaron rutas típicas de Burp/Metasploit. Revisa manualmente si tienes Burp Pro en ruta no estándar."
fi

# 5) Summarize dry-run plan
echo
echo "================= PLAN (DRY-RUN SUMMARY) ================="
echo "Backups saved in: $BACKUP_DIR"
echo "Essential packages (not removed): ${#ESSENTIAL_PKGS[@]}"
echo "Keep packages explicitly: ${KEEP_PACKAGES[*]}"
echo "Detected extra keep paths: ${EXTRA_KEEP_PATHS[*]:-none}"
echo "Manual packages candidates for purge: ${#CANDIDATES[@]}"
if [ ${#CANDIDATES[@]} -le 50 ]; then
  printf "Candidates list:\n%s\n" "${CANDIDATES[*]}"
else
  printf "Candidates list is long; saved to %s/apt_manual_%s.txt\n" "$BACKUP_DIR" "$TIMESTAMP"
fi
echo "Directories considered for cleanup: ${CLEAN_DIRS[*]}"
echo "Quarantine dir (for moved items): $BACKUP_DIR/quarantine"
echo "Log: $LOG"
echo "========================================================="
echo

if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] No se harán cambios. Re-ejecuta con --yes para aplicar."
  exit 0
fi

# Confirm action
if [ "$FORCE_NO_PROMPT" = false ]; then
  read -p "CONFIRM: This will purge the ${#CANDIDATES[@]} manual packages and clean many directories. Type 'IAGREE' to proceed: " ans
  if [ "$ans" != "IAGREE" ]; then
    echo "Aborted by user."
    exit 1
  fi
fi

# 6) Apply removals (APT purge)
echo "[STEP 6] Purging candidate packages (apt purge --auto-remove)..."
mkdir -p "$BACKUP_DIR/quarantine"
# We'll iterate in batches to avoid overloading apt
BATCH=30
i=0
pkg_batch=()
for p in "${CANDIDATES[@]}"; do
  pkg_batch+=("$p")
  ((i++))
  if [ $i -ge $BATCH ]; then
    echo "[APT] Purging batch of $i packages..."
    apt-get -y purge --allow-change-held-packages "${pkg_batch[@]}" || echo "[WARN] Some packages in batch failed to purge"
    apt-get -y autoremove || true
    pkg_batch=(); i=0
  fi
done
if [ ${#pkg_batch[@]} -gt 0 ]; then
  echo "[APT] Purging final batch of ${#pkg_batch[@]} packages..."
  apt-get -y purge --allow-change-held-packages "${pkg_batch[@]}" || echo "[WARN] Some packages failed to purge"
  apt-get -y autoremove || true
fi

# 7) Clean apt caches and orphaned configs
echo "[STEP 7] Limpieza de caches y paquetes residuales..."
apt-get clean
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge || true

# 8) Remove snaps / flatpak if present (user confirmation)
if command -v snap >/dev/null 2>&1; then
  echo "[STEP 8] snap detected: removing snaps and snapd..."
  snap list | awk 'NR>1{print $1}' | xargs -r -n1 snap remove --purge || true
  apt-get -y purge snapd || true
fi
if command -v flatpak >/dev/null 2>&1; then
  echo "[STEP 8] flatpak detected: removing user flatpaks (non-destructive)..."
  flatpak list --app --columns=application | xargs -r flatpak uninstall -y || true
  apt-get -y purge flatpak || true
fi

# 9) Clean /opt and /usr/local while preserving keep paths
echo "[STEP 9] Limpiando /opt y /usr/local (mover a quarantine en backup)..."
for d in /opt /usr/local; do
  if [ ! -d "$d" ]; then continue; fi
  for entry in "$d"/*; do
    # skip if matches any KEEP_PATHS or EXTRA_KEEP_PATHS
    keep=false
    for kp in "${KEEP_PATHS[@]}" "${EXTRA_KEEP_PATHS[@]}"; do
      # Use glob match
      if [[ "$entry" == $kp ]]; then keep=true; break; fi
    done
    if $keep; then
      echo "[KEEP] $entry"
      continue
    fi
    # Move to quarantine
    target="$BACKUP_DIR/quarantine${entry}"
    echo "[MOVE] $entry -> $target"
    mkdir -p "$(dirname "$target")"
    mv "$entry" "$target" || echo "[WARN] Could not move $entry"
  done
done

# 10) Remove non-system desktop entries (optional)
echo "[STEP 10] Limpiando /usr/share/applications no esenciales..."
find /usr/share/applications -maxdepth 1 -type f -print0 | while IFS= read -r -d '' f; do
  # keep entries that mention metasploit or burp
  if grep -qiE 'metasploit|burp' "$f" 2>/dev/null; then
    echo "[KEEP .desktop] $f"
    continue
  fi
  echo "[MOVE .desktop] $f -> $BACKUP_DIR/quarantine$(dirname "$f")"
  mkdir -p "$BACKUP_DIR/quarantine$(dirname "$f")"
  mv "$f" "$BACKUP_DIR/quarantine$(dirname "$f")" || true
done

# 11) Final cleanup and autoremove
echo "[STEP 11] Final apt autoremove and update caches..."
apt-get -y autoremove
apt-get -y autoclean
rm -rf /var/lib/apt/lists/*
apt-get update -o Acquire::Languages=none || true

# 12) Rebuild locale caches, update alternatives (safe ops)
echo "[STEP 12] Rebuilding caches..."
ldconfig || true

# 13) Generate restore script for reinstallation of purged packages (best-effort)
echo "[STEP 13] Generando restore script para reinstalar paquetes purgados (if needed)..."
# We saved the manual list earlier; compute removed = manual - current manual after actions
apt-mark showmanual > "$BACKUP_DIR/apt_manual_after_${TIMESTAMP}.txt"
comm -23 "$BACKUP_DIR/apt_manual_${TIMESTAMP}.txt" "$BACKUP_DIR/apt_manual_after_${TIMESTAMP}.txt" > "$BACKUP_DIR/purged_manual_pkgs_${TIMESTAMP}.txt" || true
cat > "$BACKUP_DIR/restore_purged_pkgs.sh" <<'SH'
#!/usr/bin/env bash
# Restore (best-effort) script: reinstala paquetes purgados listados en purged_manual_pkgs
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Run as root"; exit 1; fi
PKGLIST_FILE="'$BACKUP_DIR/purged_manual_pkgs_${TIMESTAMP}.txt'"
if [ ! -s "$PKGLIST_FILE" ]; then echo "No purged package list found at $PKGLIST_FILE"; exit 0; fi
xargs -a "$PKGLIST_FILE" apt-get install -y
SH
chmod +x "$BACKUP_DIR/restore_purged_pkgs.sh"
echo "[INFO] Restore script at $BACKUP_DIR/restore_purged_pkgs.sh"

# 14) Finish
echo "[DONE] Deep clean finished at $(date)."
echo "Backups and quarantine stored at $BACKUP_DIR"
echo "Log: $LOG"
echo "If something critical was removed, run: sudo bash $BACKUP_DIR/restore_purged_pkgs.sh"

exit 0