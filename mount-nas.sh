#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# NAS Mount Setup
# Version: 2.0.0
#
# Mounts NAS_BACKUP_DIR (config/backup.conf) over CIFS, adding the fstab
# entry and credentials file if they don't already exist. install.sh and
# restore.sh call this automatically; run it directly to pre-stage a fresh
# VM or to repair the mount without touching GitLab.
#
# Usage:
#   sudo ./mount-nas.sh
###############################################################################

SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

require_root

source "$SCRIPT_DIR/config/backup.conf"

resolve_log_dir "${BACKUP_ROOT}/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/gitlab_mount_nas_${TIMESTAMP}.log"

require_commands mountpoint

if ensure_nas_mount; then
    log "NAS mount ready."
else
    log "ERROR: Failed to mount NAS."
    exit 1
fi

echo
findmnt "$NAS_BACKUP_DIR" || true
