#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# GitLab Restore Script
# Version: 2.1.0
#
# Usage:
#   sudo ./restore.sh                     # pick a backup interactively
#   sudo ./restore.sh /path/to/backup.tar.gz
# ============================================================================

SCRIPT_VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

require_root

source "$SCRIPT_DIR/config/backup.conf"

mkdir -p "$TEMP_BACKUP_DIR"
resolve_log_dir "${BACKUP_ROOT}/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/gitlab_restore_${TIMESTAMP}.log"
WORK_DIR="$TEMP_BACKUP_DIR/restore_${TIMESTAMP}"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_commands gitlab-backup gitlab-ctl tar find awk grep

###############################################################################
# Ensure the NAS backup share is mounted (best-effort — an archive may also
# be passed in directly from local/removable media)
###############################################################################

ensure_nas_mount || log "Continuing without a confirmed NAS mount."

###############################################################################
# Resolve which archive to restore
###############################################################################

if [[ $# -ge 1 ]]; then
    ARCHIVE="$1"
    [[ -f "$ARCHIVE" ]] || { log "ERROR: Archive not found: $ARCHIVE"; exit 1; }
else
    ARCHIVE="$(select_backup_archive)"
fi

log "Using archive: $ARCHIVE"

###############################################################################
# Extract and validate
###############################################################################

ROOT="$(extract_backup_archive "$ARCHIVE" "$WORK_DIR")"

BACKUP_ID="$(read_backup_info "$ROOT" "Backup ID")"
BACKUP_TAR="$ROOT/${BACKUP_ID}_gitlab_backup.tar"

if [[ -z "$BACKUP_ID" || ! -f "$BACKUP_TAR" ]]; then
    log "ERROR: Could not determine Backup ID from backup_info.txt, or its matching *_gitlab_backup.tar is missing."
    exit 1
fi

echo
cat "$ROOT/backup_info.txt"
echo

BACKUP_VERSION="$(read_backup_info "$ROOT" "GitLab Version")"
INSTALLED_VERSION=$(cat /opt/gitlab/embedded/service/gitlab-rails/VERSION)

echo "Installed Version : $INSTALLED_VERSION"
echo "Backup Version    : $BACKUP_VERSION"
echo

if [[ "$INSTALLED_VERSION" != "$BACKUP_VERSION" ]]; then
    log "ERROR: GitLab version mismatch (installed: $INSTALLED_VERSION, backup: $BACKUP_VERSION)."
    log "Use install.sh on a fresh VM to install the matching version first, then restore."
    exit 1
fi

echo "WARNING: This will overwrite the current GitLab instance."
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { log "Restore cancelled."; exit 0; }

###############################################################################
# Restore
###############################################################################

log "Stopping GitLab application services..."
gitlab-ctl stop puma
gitlab-ctl stop sidekiq

cp "$BACKUP_TAR" "$GITLAB_BACKUP_DIR/"

log "Running restore..."
gitlab-backup restore BACKUP="$BACKUP_ID" force=yes

cp "$ROOT/gitlab.rb" /etc/gitlab/gitlab.rb
cp "$ROOT/gitlab-secrets.json" /etc/gitlab/gitlab-secrets.json

# Certs go back before reconfigure so nginx picks them up. Archives from
# before script 2.1.0 don't have them — skip, and leave the VM's own.
for CERT_DIR in ssl trusted-certs; do
    if [[ -d "$ROOT/$CERT_DIR" ]]; then
        log "Restoring /etc/gitlab/$CERT_DIR..."
        mkdir -p "/etc/gitlab/$CERT_DIR"
        cp -a "$ROOT/$CERT_DIR/." "/etc/gitlab/$CERT_DIR/"
    fi
done

if [[ -d "$ROOT/ssh_host_keys" ]]; then
    log "Restoring SSH host keys..."
    cp -p "$ROOT"/ssh_host_keys/ssh_host_* /etc/ssh/
    chown root:root /etc/ssh/ssh_host_*
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub
    systemctl restart ssh || log "WARNING: Could not restart ssh — restored host keys apply after a reboot."
else
    log "Archive has no SSH host keys — keeping this VM's own (clients will see a host key change)."
fi

log "Reconfiguring GitLab..."
gitlab-ctl reconfigure

log "Restarting GitLab..."
gitlab-ctl restart

log "GitLab status:"
gitlab-ctl status | tee -a "$LOG_FILE"

log "Restore completed successfully. (Backup ID: $BACKUP_ID)"
