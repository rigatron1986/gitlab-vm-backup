#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# GitLab Backup Script
# Version: 2.1.0
###############################################################################

SCRIPT_VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

require_root

###############################################################################
# Load configuration
###############################################################################

source "$SCRIPT_DIR/config/backup.conf"

mkdir -p "$LOCAL_BACKUP_DIR"
mkdir -p "$TEMP_BACKUP_DIR"
resolve_log_dir "${BACKUP_ROOT}/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
HOSTNAME=$(hostname)

LOG_FILE="$LOG_DIR/gitlab_backup_${TIMESTAMP}.log"

###############################################################################
# Cleanup handler
###############################################################################

WORK_DIR=""

cleanup() {
    if [[ -n "${WORK_DIR:-}" ]] && [[ -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

###############################################################################
# Verify required commands
###############################################################################

require_commands gitlab-backup gitlab-psql tar rsync dpkg-query

###############################################################################
# Wait for GitLab database
###############################################################################

log "Waiting for GitLab database..."

COUNT=0

until gitlab-psql -c "SELECT 1;" >/dev/null 2>&1
do
    COUNT=$((COUNT + 1))

    if [ "$COUNT" -ge "$WAIT_RETRIES" ]; then
        log "ERROR: GitLab database did not become available."
        exit 1
    fi

    sleep "$WAIT_INTERVAL"
done

log "Database is online."

###############################################################################
# Create GitLab backup
###############################################################################

log "Running GitLab backup..."

gitlab-backup create CRON=1 >>"$LOG_FILE" 2>&1

LATEST_BACKUP=$(find "$GITLAB_BACKUP_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*_gitlab_backup.tar" \
    -printf "%T@ %p\n" | sort -nr | head -1 | cut -d' ' -f2-)

if [[ ! -f "$LATEST_BACKUP" ]]; then
    log "ERROR: GitLab backup tar not found."
    exit 1
fi

# This is the ID gitlab-backup itself assigned (e.g. 1699999999_2024_01_01_16.7.0).
# It has to survive intact into the archive — restore.sh needs the exact same
# ID to hand back to `gitlab-backup restore BACKUP=<id>`.
BACKUP_ID="$(basename "$LATEST_BACKUP" _gitlab_backup.tar)"

###############################################################################
# Detect installed edition (needed by install.sh to pick the right package)
###############################################################################

GITLAB_EDITION="ce"
if dpkg -l gitlab-ee 2>/dev/null | grep -q '^ii'; then
    GITLAB_EDITION="ee"
fi

###############################################################################
# Create temporary package
###############################################################################

WORK_DIR="$TEMP_BACKUP_DIR/gitlab_backup_$TIMESTAMP"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

cp "$LATEST_BACKUP" "$WORK_DIR/${BACKUP_ID}_gitlab_backup.tar"
cp /etc/gitlab/gitlab.rb "$WORK_DIR/"
cp /etc/gitlab/gitlab-secrets.json "$WORK_DIR/"

# Not part of gitlab-backup, but needed for a rebuilt VM to look identical to
# clients: without the SSH host keys every git-over-SSH user gets a "host
# identification has changed" warning, and without the certs HTTPS breaks.
# Both are optional — restore.sh skips whatever an archive doesn't have.
HOST_KEYS=(/etc/ssh/ssh_host_*)
if [[ -e "${HOST_KEYS[0]}" ]]; then
    mkdir -p "$WORK_DIR/ssh_host_keys"
    cp -p "${HOST_KEYS[@]}" "$WORK_DIR/ssh_host_keys/"
    log "Included SSH host keys."
else
    log "WARNING: No SSH host keys found in /etc/ssh — not included."
fi

for CERT_DIR in ssl trusted-certs; do
    if [[ -d "/etc/gitlab/$CERT_DIR" ]] && [[ -n "$(ls -A "/etc/gitlab/$CERT_DIR")" ]]; then
        cp -a "/etc/gitlab/$CERT_DIR" "$WORK_DIR/"
        log "Included /etc/gitlab/$CERT_DIR."
    fi
done

GITLAB_VERSION=$(cat /opt/gitlab/embedded/service/gitlab-rails/VERSION)

cat > "$WORK_DIR/backup_info.txt" <<EOF
Backup Date    : $(date "+%Y-%m-%d %H:%M:%S %Z")
Hostname       : $HOSTNAME
GitLab Version : $GITLAB_VERSION
GitLab Edition : $GITLAB_EDITION
Backup ID      : $BACKUP_ID
Script Version : $SCRIPT_VERSION
GitLab Archive : $(basename "$LATEST_BACKUP")
EOF

###############################################################################
# Create archive
###############################################################################

ARCHIVE="$LOCAL_BACKUP_DIR/gitlab_backup_${TIMESTAMP}.tar.gz"
TEMP_ARCHIVE="${ARCHIVE}.tmp"

log "Creating archive..."

sync

tar --warning=no-file-changed \
    --ignore-failed-read \
    -czf "$TEMP_ARCHIVE" \
    -C "$TEMP_BACKUP_DIR" \
    "gitlab_backup_$TIMESTAMP"

mv "$TEMP_ARCHIVE" "$ARCHIVE"

log "Archive created successfully."

###############################################################################
# Verify archive
###############################################################################

if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    log "Archive verification successful."
else
    log "ERROR: Archive verification failed."
    rm -f "$ARCHIVE"
    exit 1
fi

###############################################################################
# Remove original GitLab generated backup
###############################################################################

rm -f "$LATEST_BACKUP"

###############################################################################
# Sync pending backups to NAS
###############################################################################

if [[ -d "$NAS_BACKUP_DIR" ]] && touch "$NAS_BACKUP_DIR/.write_test" 2>/dev/null; then

    rm -f "$NAS_BACKUP_DIR/.write_test"

    log "Syncing backups to NAS..."

    for FILE in "$LOCAL_BACKUP_DIR"/*.tar.gz
    do
        [[ -f "$FILE" ]] || continue

        if rsync -a "$FILE" "$NAS_BACKUP_DIR/"; then
            rm -f "$FILE"
            log "Uploaded $(basename "$FILE")"
        else
            log "Failed to upload $(basename "$FILE")"
        fi
    done

else

    log "NAS unavailable. Backups retained locally."

fi

###############################################################################
# Retention
###############################################################################

find "$LOCAL_BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete

if [[ -d "$NAS_BACKUP_DIR" ]]; then
    find "$NAS_BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete
fi

find "$LOG_DIR" -type f -mtime +"$RETENTION_DAYS" -delete

###############################################################################
# Finished
###############################################################################

log "Backup completed successfully. (Backup ID: $BACKUP_ID, GitLab $GITLAB_VERSION-$GITLAB_EDITION)"
