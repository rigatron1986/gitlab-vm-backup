#!/usr/bin/env bash
# Shared helpers for backup.sh / restore.sh / install.sh.
# Expects LOG_FILE to already be set by the sourcing script.

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo
        echo "ERROR: This script must be run as root."
        echo
        echo "Usage:"
        echo "    sudo ./$(basename "$0")"
        echo
        exit 1
    fi
}

require_commands() {
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR: Required command '$cmd' not found."
            exit 1
        fi
    done
}

# Lists archives from NAS_BACKUP_DIR (falling back to LOCAL_BACKUP_DIR for
# anything NAS doesn't have, e.g. backups kept locally because the NAS was
# unavailable at backup time), lets the user pick one, and prints the chosen
# path on stdout.
select_backup_archive() {
    declare -A seen
    ARCHIVES=()

    if [[ -n "${NAS_BACKUP_DIR:-}" && -d "$NAS_BACKUP_DIR" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            seen["$(basename "$path")"]=1
            ARCHIVES+=("$path")
        done < <(find "$NAS_BACKUP_DIR" -maxdepth 1 -type f -name "gitlab_backup_*.tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2-)
    fi

    if [[ -n "${LOCAL_BACKUP_DIR:-}" && -d "$LOCAL_BACKUP_DIR" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            local name
            name="$(basename "$path")"
            [[ -n "${seen[$name]:-}" ]] && continue
            ARCHIVES+=("$path (local only — not on NAS)")
        done < <(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f -name "gitlab_backup_*.tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2-)
    fi

    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        log "ERROR: No backup archives found in NAS_BACKUP_DIR or LOCAL_BACKUP_DIR."
        exit 1
    fi

    echo >&2
    echo "Available Backups" >&2
    echo "-----------------" >&2
    local i
    for i in "${!ARCHIVES[@]}"; do
        printf "%2d) %s\n" "$((i + 1))" "${ARCHIVES[$i]}" >&2
    done
    echo >&2

    read -rp "Select backup: " SEL
    [[ "$SEL" =~ ^[0-9]+$ ]] || { log "Invalid selection."; exit 1; }
    ((SEL >= 1 && SEL <= ${#ARCHIVES[@]})) || { log "Invalid selection."; exit 1; }

    # Strip the " (local only — not on NAS)" annotation before returning the path.
    echo "${ARCHIVES[$((SEL - 1))]}" | sed -E 's/ \(local only.*\)$//'
}

# Extracts $1 (archive path) into $2 (work dir), validates the expected
# contents are present, and prints the extracted root directory on stdout.
extract_backup_archive() {
    local archive="$1"
    local work_dir="$2"

    [[ -f "$archive" ]] || { log "ERROR: Archive not found: $archive"; exit 1; }

    mkdir -p "$work_dir"
    tar -xzf "$archive" -C "$work_dir"

    local root
    root=$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -n "$root" ]] || { log "ERROR: Archive did not contain the expected top-level folder."; exit 1; }

    [[ -f "$root/backup_info.txt" ]] || { log "ERROR: Missing backup_info.txt in archive."; exit 1; }
    [[ -f "$root/gitlab.rb" ]] || { log "ERROR: Missing gitlab.rb in archive."; exit 1; }
    [[ -f "$root/gitlab-secrets.json" ]] || { log "ERROR: Missing gitlab-secrets.json in archive."; exit 1; }

    if ! find "$root" -maxdepth 1 -name "*_gitlab_backup.tar" -print -quit | grep -q .; then
        log "ERROR: Missing <backup-id>_gitlab_backup.tar in archive."
        exit 1
    fi

    echo "$root"
}

# Creates LOG_DIR (normally on NAS_BACKUP_DIR). If that can't be created —
# e.g. the NAS is unreachable — falls back to $1 (a local path) so the
# caller can still log and run, instead of aborting on an unreachable mount.
# Must run before LOG_FILE is set (log() isn't usable yet), so failures are
# reported directly to stderr.
resolve_log_dir() {
    local fallback="$1"

    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        return 0
    fi

    echo "WARNING: Could not create LOG_DIR ($LOG_DIR) — is the NAS reachable? Falling back to $fallback" >&2
    LOG_DIR="$fallback"
    mkdir -p "$LOG_DIR"
}

# Reads a "Field: value" line out of a backup_info.txt.
read_backup_info() {
    local root="$1"
    local field="$2"
    grep "^${field}[[:space:]]*:" "$root/backup_info.txt" | head -1 | awk -F': ' '{print $2}' | xargs
}

# Ensures NAS_BACKUP_DIR is mounted via CIFS, using NAS_HOST/NAS_SHARE and the
# CIFS_* options from backup.conf. Installs cifs-utils and creates the
# credentials file (prompting interactively) if needed, adds an fstab entry if
# one isn't already there, then mounts. Idempotent — safe to call on a VM that
# already has it mounted and configured. Never aborts the caller; logs a
# warning and returns non-zero on failure so the caller decides what to do.
ensure_nas_mount() {
    if [[ -z "${NAS_HOST:-}" || -z "${NAS_SHARE:-}" || -z "${NAS_BACKUP_DIR:-}" ]]; then
        log "WARNING: NAS_HOST/NAS_SHARE/NAS_BACKUP_DIR not configured. Skipping NAS mount."
        return 1
    fi

    if ! command -v mount.cifs >/dev/null 2>&1; then
        log "Installing cifs-utils..."
        apt-get update >>"$LOG_FILE" 2>&1
        apt-get install -y cifs-utils >>"$LOG_FILE" 2>&1
    fi

    if [[ ! -f "$CIFS_CREDENTIALS_FILE" ]]; then
        log "No CIFS credentials file at $CIFS_CREDENTIALS_FILE. Creating it now."
        echo
        read -rp "SMB username for //${NAS_HOST}/${NAS_SHARE}: " SMB_USER
        read -rsp "SMB password: " SMB_PASS
        echo

        umask 177
        {
            echo "username=$SMB_USER"
            echo "password=$SMB_PASS"
        } > "$CIFS_CREDENTIALS_FILE"
        umask 022

        chown root:root "$CIFS_CREDENTIALS_FILE"
        chmod 600 "$CIFS_CREDENTIALS_FILE"
        unset SMB_USER SMB_PASS
    fi

    mkdir -p "$NAS_BACKUP_DIR"

    if ! grep -qE "^[^#[:space:]].*[[:space:]]${NAS_BACKUP_DIR}[[:space:]]" /etc/fstab; then
        log "Adding fstab entry for $NAS_BACKUP_DIR..."
        {
            echo "//${NAS_HOST}/${NAS_SHARE} ${NAS_BACKUP_DIR} cifs credentials=${CIFS_CREDENTIALS_FILE},vers=${CIFS_VERS},_netdev,nofail,x-systemd.automount,uid=${CIFS_UID},gid=${CIFS_GID},file_mode=${CIFS_FILE_MODE},dir_mode=${CIFS_DIR_MODE} 0 0"
        } >> /etc/fstab
        systemctl daemon-reload
    fi

    if ! mountpoint -q "$NAS_BACKUP_DIR"; then
        log "Mounting $NAS_BACKUP_DIR..."
        mount -a
    fi

    if mountpoint -q "$NAS_BACKUP_DIR"; then
        log "$NAS_BACKUP_DIR is mounted."
        return 0
    else
        log "WARNING: $NAS_BACKUP_DIR is not mounted. Check network/NAS availability and $CIFS_CREDENTIALS_FILE."
        return 1
    fi
}
