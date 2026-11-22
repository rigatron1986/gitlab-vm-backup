#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# GitLab Version-Matched Installer
# Version: 2.0.0
#
# For bringing up a FRESH Ubuntu VM from a gitlab_backup archive:
#   1. Reads the GitLab version + edition recorded in the backup.
#   2. Adds GitLab's official apt repo for that edition (if not already added).
#   3. Installs that exact GitLab package version.
#   4. Hands off to restore.sh to restore the backup into it.
#
# Usage:
#   sudo ./install.sh                     # pick a backup interactively
#   sudo ./install.sh /path/to/backup.tar.gz
###############################################################################

SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

require_root

source "$SCRIPT_DIR/config/backup.conf"

mkdir -p "$TEMP_BACKUP_DIR"
resolve_log_dir "${BACKUP_ROOT}/logs"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/gitlab_install_${TIMESTAMP}.log"
WORK_DIR="$TEMP_BACKUP_DIR/install_${TIMESTAMP}"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_commands curl tar find awk grep apt-get dpkg-query apt-cache

###############################################################################
# Ensure the NAS backup share is mounted (best-effort — an archive may also
# be passed in directly from local/removable media)
###############################################################################

ensure_nas_mount || log "Continuing without a confirmed NAS mount."

###############################################################################
# Resolve which archive to install from
###############################################################################

if [[ $# -ge 1 ]]; then
    ARCHIVE="$1"
    [[ -f "$ARCHIVE" ]] || { log "ERROR: Archive not found: $ARCHIVE"; exit 1; }
else
    ARCHIVE="$(select_backup_archive)"
fi

log "Using archive: $ARCHIVE"

ROOT="$(extract_backup_archive "$ARCHIVE" "$WORK_DIR")"

GITLAB_VERSION="$(read_backup_info "$ROOT" "GitLab Version")"
GITLAB_EDITION="$(read_backup_info "$ROOT" "GitLab Edition")"
GITLAB_EDITION="${GITLAB_EDITION:-ce}"
PACKAGE="gitlab-${GITLAB_EDITION}"

if [[ -z "$GITLAB_VERSION" ]]; then
    log "ERROR: Could not read 'GitLab Version' from backup_info.txt."
    exit 1
fi

log "Backup requires: $PACKAGE $GITLAB_VERSION"

###############################################################################
# Check what's already installed
###############################################################################

INSTALLED_PACKAGE=""
INSTALLED_VERSION=""

for pkg in gitlab-ce gitlab-ee; do
    if dpkg-query -W -f='${Version}' "$pkg" >/dev/null 2>&1; then
        INSTALLED_PACKAGE="$pkg"
        INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' "$pkg")"
        break
    fi
done

if [[ -n "$INSTALLED_PACKAGE" ]]; then
    if [[ "$INSTALLED_PACKAGE" == "$PACKAGE" && "$INSTALLED_VERSION" == "$GITLAB_VERSION"-* ]]; then
        log "$PACKAGE $INSTALLED_VERSION is already installed and matches the backup. Skipping install."
        exec "$SCRIPT_DIR/restore.sh" "$ARCHIVE"
    fi

    log "ERROR: $INSTALLED_PACKAGE $INSTALLED_VERSION is already installed, but the backup needs $PACKAGE $GITLAB_VERSION."
    log "This installer only provisions a fresh VM. Jumping GitLab versions in place is not supported here"
    log "(GitLab requires following its documented upgrade path). Use restore.sh directly if versions already match."
    exit 1
fi

###############################################################################
# Add GitLab's official apt repository (if not already configured)
###############################################################################

REPO_LIST="/etc/apt/sources.list.d/gitlab_gitlab-${GITLAB_EDITION}.list"

if [[ ! -f "$REPO_LIST" ]]; then
    log "Adding GitLab's official apt repository for $PACKAGE..."
    curl -s "https://packages.gitlab.com/install/repositories/gitlab/${PACKAGE}/script.deb.sh" | bash >>"$LOG_FILE" 2>&1
else
    log "GitLab apt repository already configured."
    apt-get update >>"$LOG_FILE" 2>&1
fi

###############################################################################
# Find the exact package version matching the backup
###############################################################################

log "Looking up available $PACKAGE package versions..."

MATCHED_VERSION="$(apt-cache madison "$PACKAGE" | awk '{print $3}' | grep "^${GITLAB_VERSION}-" | head -1)"

if [[ -z "$MATCHED_VERSION" ]]; then
    log "ERROR: No $PACKAGE package found for version $GITLAB_VERSION in the configured apt repository."
    log "This version may have been removed from GitLab's package repo. Check https://packages.gitlab.com/gitlab/$PACKAGE"
    exit 1
fi

log "Matched package version: $MATCHED_VERSION"

###############################################################################
# Install
###############################################################################

log "Installing $PACKAGE=$MATCHED_VERSION..."

EXTERNAL_URL="$GITLAB_EXTERNAL_URL" apt-get install -y "${PACKAGE}=${MATCHED_VERSION}" >>"$LOG_FILE" 2>&1

log "Holding $PACKAGE at $MATCHED_VERSION to prevent an unattended apt upgrade from moving it."
apt-mark hold "$PACKAGE" >>"$LOG_FILE" 2>&1

log "$PACKAGE $MATCHED_VERSION installed."

###############################################################################
# Hand off to restore.sh
###############################################################################

log "Handing off to restore.sh..."

exec "$SCRIPT_DIR/restore.sh" "$ARCHIVE"
