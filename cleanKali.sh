#!/usr/bin/env bash
# cleanup_duplicates_and_tmp.sh
# Advanced duplicate and temporary file cleaner for Linux
# - Default: dry-run (no deletions)
# - Moves duplicates to quarantine (preserves paths) unless --delete
# - Parallel hashing, size/date filters, exclusions, and restore helper
#
# Usage examples:
#  ./cleanup_duplicates_and_tmp.sh --paths "$HOME /tmp" --min-size 1M --quarantine /var/quarantine --dry-run
#  ./cleanup_duplicates_and_tmp.sh --paths /home/user --min-size 5K --keep largest --delete
#
# Author: Expert-level helper
# Date: 2025-11-11
set -euo pipefail

#######################
# Defaults / config
#######################
DRY_RUN=true
DELETE=false
VERBOSE=true
MIN_SIZE="1K"          # min file size to consider for dup check (supports find syntax: 1K, 5M)
HASH_ALGO="sha256sum"  # or sha1sum/md5sum but sha256 recommended
PARALLEL_JOBS=4
KEEP_POLICY="oldest"   # options: oldest | newest | largest
QUARANTINE_DIR="/var/quarantine/duplicates_$(date +%Y%m%d_%H%M%S)"
LOGFILE="/var/log/cleanup_duplicates_$(date +%Y%m%d_%H%M%S).log"
EXCLUDE_PATHS=("/proc" "/sys" "/dev" "/run" "/var/lib/docker" "/var/snap" "/snap" "/mnt" "/media")
TARGET_PATHS=("$HOME" "/tmp")
TEMP_CLEAN=true        # enable cleaning of common temp/cache dirs (user-level)
DRY_RUN_MSG="(dry-run) "
SUMMARY_TMP="/tmp/cleanup_summary_$$.txt"
RESTORE_SCRIPT="/usr/local/bin/restore_quarantine_$(date +%Y%m%d_%H%M%S).sh"

# helper: print usage
usage(){
  cat <<EOF
cleanup_duplicates_and_tmp.sh — advanced duplicate/temp cleaner

Options:
  --paths "p1 p2 ..."       Paths to scan (default: $HOME and /tmp)
  --min-size SIZE           Minimum file size to consider (find format, e.g. 1K, 5M). Default $MIN_SIZE
  --parallel N              Number of parallel hashing jobs (default $PARALLEL_JOBS)
  --keep [oldest|newest|largest]  Which file to keep in duplicate groups (default $KEEP_POLICY)
  --quarantine DIR          Directory to move duplicates into (default $QUARANTINE_DIR)
  --delete                  Delete duplicates permanently instead of quarantining
  --dry-run / --no-dry-run  Dry run (default) or actually perform actions
  --no-temp-clean           Skip temp/cache cleanup
  --exclude PATH            Add an exclusion path (can be used multiple times)
  --verbose / --quiet       Verbose output (default verbose)
  -h, --help                Show this help

Examples:
  # Dry-run on home and /tmp, min size 1M, 8 parallel hashes
  ./cleanup_duplicates_and_tmp.sh --min-size 1M --parallel 8 --dry-run

  # Actually quarantine duplicates and clean user temp caches
  sudo ./cleanup_duplicates_and_tmp.sh --paths "/home /tmp" --min-size 5K --quarantine /var/quarantine --no-temp-clean=false

EOF
  exit 1
}

#######################
# Parse args (simple)
#######################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths) shift; IFS=' ' read -r -a TARGET_PATHS <<< "$1"; shift;;
    --min-size) MIN_SIZE="$2"; shift 2;;
    --parallel) PARALLEL_JOBS="$2"; shift 2;;
    --keep) KEEP_POLICY="$2"; shift 2;;
    --quarantine) QUARANTINE_DIR="$2"; shift 2;;
    --delete) DELETE=true; DRY_RUN=false; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    --no-temp-clean) TEMP_CLEAN=false; shift;;
    --exclude) EXCLUDE_PATHS+=("$2"); shift 2;;
    --verbose) VERBOSE=true; shift;;
    --quiet) VERBOSE=false; shift;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# If delete explicitly requested, ensure user knows
if [ "$DELETE" = true ]; then
  echo "WARNING: --delete was specified: duplicates will be permanently removed (no restore)."
fi

# Ensure quarantine dir exists (unless delete)
if [ "$DELETE" = false ]; then
  mkdir -p "$QUARANTINE_DIR"
fi
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
echo "Run started: $(date)" >> "$LOGFILE"

# normalize exclude find args
_build_exclude_args(){
  local args=()
  for p in "${EXCLUDE_PATHS[@]}"; do
    args+=( -path "$p" -prune -o )
  done
  echo "${args[@]}"
}

# function to convert human size to -size find pattern (if user passed 1K/5M use as is)
_find_size_expr(){
  # find accepts size in c/k/M/G; we pass directly
  echo "-size +${MIN_SIZE}"
}

# Create temporary files
HASH_OUT="/tmp/cleanup_hashes_$$.txt"
GROUPS_OUT="/tmp/cleanup_groups_$$.txt"
> "$HASH_OUT"
> "$GROUPS_OUT"

log(){
  local msg="$*"
  echo "$(date +'%F %T') $msg" | tee -a "$LOGFILE"
}

if [ "$VERBOSE" = true ]; then
  log "Configuration: TARGET_PATHS=${TARGET_PATHS[*]}, MIN_SIZE=$MIN_SIZE, PARALLEL=$PARALLEL_JOBS, KEEP_POLICY=$KEEP_POLICY, QUARANTINE=$QUARANTINE_DIR, DELETE=$DELETE, TEMP_CLEAN=$TEMP_CLEAN"
fi

####################
# Step 1: Find candidate files
####################
log "Finding candidate files (this may take a while)..."

# Build find command across target paths while applying excludes
FIND_CMD=(find)
for p in "${TARGET_PATHS[@]}"; do FIND_CMD+=("$p"); done
# Append prune/exclude
EXCLUDE_ARGS=( $(_build_exclude_args) )
if [ ${#EXCLUDE_ARGS[@]} -gt 0 ]; then
  FIND_CMD+=("${EXCLUDE_ARGS[@]}")
fi
# Only regular files and min size, skip links
FIND_CMD+=( -type f $(_find_size_expr) -print0 )

# Run find and pipe to parallel sha256sum (xargs -0 -n1 -P)
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  log "No sha256 tool found. Aborting."
  exit 1
fi

# Use xargs parallel execution to hash files (handles N jobs)
# We output: <hash>  <filepath>
log "Hashing files with $HASH_CMD using $PARALLEL_JOBS parallel jobs..."
# Use a subshell to handle NUL separated filenames
# Some systems' xargs don't support -0 -P, but most Linux do. We fallback if not available.
if find / -maxdepth 0 >/dev/null 2>&1; then
  # standard path
  if xargs -0 -n1 -P "$PARALLEL_JOBS" -I{} bash -c "$HASH_CMD '{}' 2>/dev/null || echo 'ERR  {}'" < <("${FIND_CMD[@]}"); then
    # redirect to HASH_OUT
    "${FIND_CMD[@]}" | xargs -0 -n1 -P "$PARALLEL_JOBS" -I{} bash -c "$HASH_CMD '{}' 2>/dev/null || echo 'ERR  {}'" > "$HASH_OUT" 2>/dev/null || true
  else
    # fallback slower single-thread
    log "Parallel hashing failed, fallback to single-thread"
    "${FIND_CMD[@]}" | xargs -0 -n1 bash -c "$HASH_CMD '{}' 2>/dev/null || echo 'ERR  {}'" > "$HASH_OUT" 2>/dev/null || true
  fi
else
  # last-resort fallback: run find and hash line by line
  "${FIND_CMD[@]}" | while IFS= read -r -d '' f; do
    $HASH_CMD "$f" 2>/dev/null || echo "ERR  $f"
  done > "$HASH_OUT"
fi

# Remove lines starting with ERR and empty lines
grep -v '^ERR' "$HASH_OUT" | sed '/^$/d' > "${HASH_OUT}.clean"
mv "${HASH_OUT}.clean" "$HASH_OUT"

# Check how many hashed entries
TOTAL_HASHES=$(wc -l < "$HASH_OUT" 2>/dev/null || echo 0)
log "Total hashed files: $TOTAL_HASHES"

####################
# Step 2: Group by hash and find duplicates
####################
log "Grouping by hash to find duplicates..."
# Normalize sha256sum output: "<hash>  <filename>" or "hash  -"
# We'll sort by hash and output groups with count >1
cut -d' ' -f1 "$HASH_OUT" | nl -v0 -w1 -s' ' > /tmp/hashes_index_$$.txt || true
# create associative: use awk to group
awk '{
  h=$1
  # Reconstruct filename from the rest of the line (handles spaces)
  $1=""; sub(/^ /,"")
  file=$0
  print h "::::" file
}' "$HASH_OUT" | sort > /tmp/hash_file_pairs_$$.txt

# Build groups file: hash -> list of files
awk -F'::::' '{
  a[$1]= (a[$1] ? a[$1] RS $2 : $2)
} END {
  for (k in a) {
    split(a[k], arr, "\n")
    if (length(arr) > 1) {
      printf("%s\n", k)
      for(i in arr) print "  " arr[i]
      print ""
    }
  }
}' /tmp/hash_file_pairs_$$.txt > "$GROUPS_OUT" || true

DUP_GROUPS_COUNT=$(grep -c '^$' -v "$GROUPS_OUT" 2>/dev/null || true)
if [ ! -s "$GROUPS_OUT" ]; then
  log "No duplicates found. Exiting."
  echo "No duplicates found." | tee -a "$LOGFILE"
  exit 0
fi

log "Duplicate groups created at $GROUPS_OUT"
log "Preview (first 80 lines):"
sed -n '1,80p' "$GROUPS_OUT" | sed -n '1,80p' | tee -a "$LOGFILE"

####################
# Step 3: Process each duplicate group
####################
log "Processing duplicate groups..."

# helper: choose the file to keep based on policy
choose_keep(){
  # arguments: list of files (newline separated)
  local files=()
  while IFS= read -r line; do files+=("$line"); done
  case "$KEEP_POLICY" in
    oldest)
      # keep oldest (earliest mtime)
      local keep="$(printf '%s\n' "${files[@]}" | xargs -I{} stat -c '%Y %n' {} 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2-)"
      echo "$keep"
      ;;
    newest)
      local keep="$(printf '%s\n' "${files[@]}" | xargs -I{} stat -c '%Y %n' {} 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
      echo "$keep"
      ;;
    largest)
      local keep="$(printf '%s\n' "${files[@]}" | xargs -I{} stat -c '%s %n' {} 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
      echo "$keep"
      ;;
    *)
      # default oldest
      local keep="$(printf '%s\n' "${files[@]}" | xargs -I{} stat -c '%Y %n' {} 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2-)"
      echo "$keep"
      ;;
  esac
}

# iterate groups from GROUPS_OUT (format: hash newline two-space file entries)
# We'll parse by detecting lines that look like hashes (64 hex) — robust enough for sha256
current_hash=""
declare -a current_files
while IFS= read -r line; do
  if [[ "$line" =~ ^[0-9a-fA-F]{64}$ ]]; then
    # process previous
    if [ "${#current_files[@]}" -gt 1 ]; then
      # choose keep file
      keepfile="$(printf '%s\n' "${current_files[@]}" | choose_keep)"
      log "Group $current_hash -> keeping: $keepfile"
      # handle others
      for f in "${current_files[@]}"; do
        if [ "$f" = "$keepfile" ]; then continue; fi
        # target action: move to quarantine or delete
        if [ "$DELETE" = true ]; then
          if [ "$DRY_RUN" = true ]; then
            log "$DRY_RUN_MSG Would delete: $f"
          else
            log "Deleting: $f"
            rm -f "$f" && echo "DEL|$f" >> "$LOGFILE"
          fi
        else
          # move to quarantine preserving path
          relpath="$(realpath --relative-to=/ "$f" 2>/dev/null || echo "$f" | sed 's|/|_|g')"
          target="$QUARANTINE_DIR/$relpath"
          target_dir="$(dirname "$target")"
          if [ "$DRY_RUN" = true ]; then
            log "$DRY_RUN_MSG Would move: $f -> $target"
          else
            mkdir -p "$target_dir"
            mv "$f" "$target"
            echo "MOVED|$f|$target" >> "$LOGFILE"
            # record restore line
            echo "mv -- \"$target\" \"$f\"" >> "$SUMMARY_TMP"
          fi
        fi
      done
    fi
    current_hash="$line"
    current_files=()
  else
    # trim
    file="$(echo "$line" | sed 's/^[[:space:]]*//')"
    current_files+=("$file")
  fi
done < "$GROUPS_OUT"

# process final group if any
if [ "${#current_files[@]}" -gt 1 ]; then
  keepfile="$(printf '%s\n' "${current_files[@]}" | choose_keep)"
  log "Group $current_hash -> keeping: $keepfile"
  for f in "${current_files[@]}"; do
    if [ "$f" = "$keepfile" ]; then continue; fi
    if [ "$DELETE" = true ]; then
      if [ "$DRY_RUN" = true ]; then
        log "$DRY_RUN_MSG Would delete: $f"
      else
        log "Deleting: $f"
        rm -f "$f" && echo "DEL|$f" >> "$LOGFILE"
      fi
    else
      relpath="$(realpath --relative-to=/ "$f" 2>/dev/null || echo "$f" | sed 's|/|_|g')"
      target="$QUARANTINE_DIR/$relpath"
      target_dir="$(dirname "$target")"
      if [ "$DRY_RUN" = true ]; then
        log "$DRY_RUN_MSG Would move: $f -> $target"
      else
        mkdir -p "$target_dir"
        mv "$f" "$target"
        echo "MOVED|$f|$target" >> "$LOGFILE"
        echo "mv -- \"$target\" \"$f\"" >> "$SUMMARY_TMP"
      fi
    fi
  done
fi

####################
# Step 4: Optional temp/cache cleanup
####################
if [ "$TEMP_CLEAN" = true ]; then
  log "Cleaning common temp/cache folders (user-level). This is conservative and won't remove caches in /var by default."

  # List of user-level temp dirs to consider (only under /home)
  user_tmp_dirs=()
  for home in /home/*; do
    if [ -d "$home/.cache" ]; then user_tmp_dirs+=("$home/.cache"); fi
    if [ -d "$home/.thumbnails" ]; then user_tmp_dirs+=("$home/.thumbnails"); fi
    if [ -d "$home/.local/share/Trash" ]; then user_tmp_dirs+=("$home/.local/share/Trash"); fi
    # browser caches (firefox/chrome)
    if [ -d "$home/.mozilla" ]; then user_tmp_dirs+=("$home/.mozilla"); fi
    if [ -d "$home/.cache/google-chrome" ]; then user_tmp_dirs+=("$home/.cache/google-chrome"); fi
    if [ -d "$home/.cache/chromium" ]; then user_tmp_dirs+=("$home/.cache/chromium"); fi
  done

  # system /tmp
  user_tmp_dirs+=("/tmp")

  for d in "${user_tmp_dirs[@]}"; do
    if [ -z "$d" ] || [ ! -d "$d" ]; then continue; fi
    if [ "$DRY_RUN" = true ]; then
      log "$DRY_RUN_MSG Would clear files older than 7 days in $d (remove only regular files)"
      find "$d" -type f -mtime +7 -print | head -n 20 | sed 's/^/  /' | tee -a "$LOGFILE"
    else
      log "Removing files older than 7 days in $d (regular files only)"
      find "$d" -type f -mtime +7 -print0 | xargs -0 -r rm -f
    fi
  done
fi

####################
# Step 5: Create restore script if quarantined
####################
if [ "$DELETE" = false ] && [ -s "$SUMMARY_TMP" ]; then
  cat > "$RESTORE_SCRIPT" <<'RS'
#!/usr/bin/env bash
# restore script generated by cleanup_duplicates_and_tmp.sh
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root to restore files."
  exit 1
fi
RS
  cat "$SUMMARY_TMP" >> "$RESTORE_SCRIPT"
  chmod +x "$RESTORE_SCRIPT"
  log "Restore script created at $RESTORE_SCRIPT"
fi

####################
# Step 6: Summary
####################
log "SUMMARY:"
if [ "$DRY_RUN" = true ]; then
  log "Mode: DRY-RUN (no files moved/deleted). Use --no-dry-run to enact changes."
else
  log "Mode: EXECUTION (changes applied)."
fi
if [ "$DELETE" = true ]; then
  log "Duplicates were deleted permanently."
else
  log "Duplicates moved to quarantine: $QUARANTINE_DIR"
  log "Restore script: $RESTORE_SCRIPT (if created)"
fi

log "Log file: $LOGFILE"
echo "Done."

# cleanup temp files
rm -f /tmp/cleanup_hashes_$$.txt /tmp/hash_file_pairs_$$.txt /tmp/hashes_index_$$.txt || true