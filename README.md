# gitlab-vm-backup

Backup and disaster-recovery tooling for a self-hosted GitLab Omnibus VM
(Ubuntu on Hyper-V), with archives stored on a NAS over CIFS.

- `backup.sh` takes a GitLab backup plus everything a rebuilt VM needs to come
  back with the same identity: `gitlab.rb`, `gitlab-secrets.json`, SSH host
  keys and TLS certificates. It runs from a systemd timer, daily and after boot.
- `install.sh` rebuilds a **fresh** VM by installing the exact GitLab version
  recorded in the backup, then restores it.
- `restore.sh` restores onto a VM that already runs the matching version.

The `docs/` folder describes a real home-lab deployment: network layout, Hyper-V
host, rebuild and host-reinstall runbooks, and a VirtualBox-to-Hyper-V
migration log. IP addresses and host names in them are placeholders.

## Documentation

| Document | Use it to… |
|---|---|
| [docs/how-it-works.md](docs/how-it-works.md) | Understand the whole setup: Windows host, Hyper-V VM, network/DNS, backups |
| [docs/rebuild-from-scratch.md](docs/rebuild-from-scratch.md) | Build a new VM, install Ubuntu and restore GitLab from the NAS backup |
| [docs/host-reinstall.md](docs/host-reinstall.md) | Export the VM before formatting the Windows PC and import it afterwards |
| [docs/migrate-virtualbox-to-hyperv.md](docs/migrate-virtualbox-to-hyperv.md) | Record of the 2026-10-06 move from VirtualBox to Hyper-V |

The rest of this README covers the scripts themselves.

------------------------------------------------------------------------

## Scripts

| Script | Runs on | Purpose |
|---|---|---|
| `backup.sh` | The live GitLab VM | Creates a `gitlab-backup`, packages it with `gitlab.rb`, `gitlab-secrets.json`, and a `backup_info.txt` manifest into one `.tar.gz`, and syncs it to a NAS (keeping it locally if the NAS is unreachable). |
| `install.sh` | A **fresh** Ubuntu VM | Ensures the NAS backup share is mounted, reads the GitLab version + edition recorded in a backup's `backup_info.txt`, adds GitLab's official apt repo, installs that exact package version, then hands off to `restore.sh`. |
| `restore.sh` | A VM with the matching GitLab version already installed | Ensures the NAS backup share is mounted, then restores a specific backup archive (or lets you pick one interactively) into the running GitLab instance. |
| `mount-nas.sh` | Any VM | Mounts `NAS_BACKUP_DIR` over CIFS (installing `cifs-utils`, creating the credentials file, and adding the `/etc/fstab` entry if needed). Called automatically by `install.sh`/`restore.sh` — run it directly to pre-stage a fresh VM or repair the mount on its own. |

`lib/common.sh` holds logic shared by all of the above (root/command checks, picking a backup archive, extracting and validating one, reading fields out of `backup_info.txt`, mounting the NAS share).

------------------------------------------------------------------------

## Disaster recovery: fresh VM → restored GitLab

```bash
git clone https://github.com/rigatron1986/gitlab-vm-backup.git ~/gitlab_backup
cd ~/gitlab_backup
nano config/backup.conf   # point NAS_HOST / NAS_SHARE / NAS_BACKUP_DIR / LOCAL_BACKUP_DIR at your backups

sudo ./install.sh
```

`install.sh` will:
1. Ensure the NAS backup share is mounted (see [Mounting the NAS backup share](#mounting-the-nas-backup-share)) — on a fresh VM this creates the credentials file and `/etc/fstab` entry for you.
2. Let you pick a backup archive (or pass one directly: `sudo ./install.sh /path/to/backup.tar.gz`).
3. Read `GitLab Version` / `GitLab Edition` from the archive's `backup_info.txt`.
4. Add GitLab's official apt repo for that edition, if not already configured.
5. Look up and install the exact matching package version (`apt-cache madison`), then `apt-mark hold` it so an unattended `apt upgrade` can't move it.
6. Call `restore.sh` with the same archive to finish the restore.

This only supports provisioning a **fresh** VM (nothing installed yet). If GitLab is already installed at a different version, `install.sh` refuses — jumping versions in place isn't supported here, since GitLab requires following its own documented upgrade path.

------------------------------------------------------------------------

## Restoring onto a VM that already has the matching version

```bash
sudo ./restore.sh                          # pick a backup interactively
sudo ./restore.sh /path/to/backup.tar.gz   # restore a specific archive
```

The restore process:
1. Ensures the NAS backup share is mounted.
2. Extracts the archive, validates required files, prints `backup_info.txt`.
3. Compares the installed GitLab version against the backup's — aborts on mismatch (use `install.sh` instead).
4. Requires you to type **YES**.
5. Stops `puma`/`sidekiq`, runs `gitlab-backup restore`, restores `gitlab.rb` and `gitlab-secrets.json`, plus `/etc/gitlab/ssl`, `/etc/gitlab/trusted-certs` and the SSH host keys when the archive has them (restarting `ssh`).
6. Runs `gitlab-ctl reconfigure` and `gitlab-ctl restart`, then shows `gitlab-ctl status`.

------------------------------------------------------------------------

## Mounting the NAS backup share

```bash
sudo ./mount-nas.sh
```

`NAS_BACKUP_DIR` is a CIFS mount (`NAS_HOST` / `NAS_SHARE` in `config/backup.conf`). `install.sh` and `restore.sh` call this automatically (best-effort — they carry on and let `select_backup_archive` fail clearly if it doesn't come up), so you normally don't need to run it yourself. It's idempotent:

1. Installs `cifs-utils` if missing.
2. If `CIFS_CREDENTIALS_FILE` (default `/root/.smbcredentials`) doesn't exist, prompts for the SMB username/password interactively and writes it there with `chmod 600`. The password is never stored in this repo or passed on the command line.
3. Adds an `/etc/fstab` entry for `NAS_BACKUP_DIR` if one isn't already present.
4. Runs `mount -a` and verifies the mount succeeded.

------------------------------------------------------------------------

## Creating a backup

```bash
sudo ./backup.sh
```

1. Waits for GitLab's database to become available.
2. Runs `gitlab-backup create`.
3. Packages the backup tar (kept under its original ID — required for restore) with `gitlab.rb`, `gitlab-secrets.json`, the SSH host keys (`/etc/ssh/ssh_host_*`), `/etc/gitlab/ssl` and `/etc/gitlab/trusted-certs` (if non-empty), and `backup_info.txt` (records GitLab version, edition, backup ID, hostname, date). The host keys and certs let a rebuilt VM present the same identity, so git-over-SSH clients don't get a host-key-changed warning.
4. Verifies the archive, uploads it to the NAS, and removes the local copy on success (keeps it locally if the NAS is unreachable).
5. Cleans up backups/logs older than `RETENTION_DAYS`.

To run this automatically after every boot and daily at 02:00, wire it into a systemd service + timer (this repo's `install.sh` is the version-matched restore installer described above, not a boot-time installer):

```ini
# /etc/systemd/system/gitlab-backup.service
[Unit]
Description=GitLab Backup
Requires=gitlab-runsvdir.service
After=gitlab-runsvdir.service

[Service]
Type=oneshot
ExecStart=/path/to/gitlab_backup/backup.sh
WorkingDirectory=/path/to/gitlab_backup
User=root
TimeoutStartSec=30min
```

```ini
# /etc/systemd/system/gitlab-backup.timer
[Unit]
Description=Run GitLab Backup After VM Startup and Daily

[Timer]
OnBootSec=5min
OnCalendar=*-*-* 02:00
Persistent=true
Unit=gitlab-backup.service

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now gitlab-backup.timer
```

`OnCalendar` matters on a long-running VM: with only `OnBootSec`, a VM that stays up for weeks gets no new backups while `RETENTION_DAYS` keeps deleting old ones. `Persistent=true` runs a missed 02:00 slot as soon as the VM is back up.

Enable the timer, not the service directly — the timer decouples the backup from boot ordering (running the service directly under `multi-user.target` can deadlock waiting on PostgreSQL before GitLab itself has finished starting).

------------------------------------------------------------------------

## Configuration (`config/backup.conf`)

```bash
NAS_BACKUP_DIR=/mnt/sources/nas/backup/gitlab

# CIFS mount for NAS_BACKUP_DIR (see mount-nas.sh)
NAS_HOST=192.168.1.120
NAS_SHARE=Backup/Gitlab

CIFS_CREDENTIALS_FILE=/root/.smbcredentials
CIFS_UID=1000
CIFS_GID=1000
CIFS_VERS=3.0
CIFS_FILE_MODE=0664
CIFS_DIR_MODE=0775

BACKUP_ROOT=/mnt/shared/backup/gitlab
LOCAL_BACKUP_DIR=${BACKUP_ROOT}/local
TEMP_BACKUP_DIR=${BACKUP_ROOT}/temp

# Logs live on the NAS share, not BACKUP_ROOT. If NAS_BACKUP_DIR isn't
# reachable when a script starts, it falls back to ${BACKUP_ROOT}/logs
# instead of aborting.
LOG_DIR=${NAS_BACKUP_DIR}/logs

GITLAB_BACKUP_DIR=/var/opt/gitlab/backups

# Used only by install.sh, for the first-time package install before the
# backup's gitlab.rb gets restored over it.
GITLAB_EXTERNAL_URL=http://localhost

RETENTION_DAYS=5

WAIT_RETRIES=40
WAIT_INTERVAL=15
```

------------------------------------------------------------------------

## Requirements

- Ubuntu (`install.sh`/`mount-nas.sh` use `apt`/`dpkg`)
- GitLab Omnibus
- `rsync`, `tar`, `curl`
- CIFS NAS share (mounted automatically by `mount-nas.sh` — see [Mounting the NAS backup share](#mounting-the-nas-backup-share))
- Root privileges

------------------------------------------------------------------------

## Archive contents

```text
gitlab_backup_YYYY-MM-DD_HH-MM-SS/
├── <backup-id>_gitlab_backup.tar
├── gitlab.rb
├── gitlab-secrets.json
├── ssh_host_keys/       # /etc/ssh/ssh_host_*            (script 2.1.0+)
├── ssl/                 # /etc/gitlab/ssl, if non-empty  (script 2.1.0+)
├── trusted-certs/       # /etc/gitlab/trusted-certs, if non-empty (2.1.0+)
└── backup_info.txt
```

The archive holds private keys and `gitlab-secrets.json`, so treat it as a secret — keep the NAS share restricted to the backup account.

`backup_info.txt` example:

```text
Backup Date    : 2026-09-07 22:00:00 UTC
Hostname       : gitlab-vm
GitLab Version : 16.7.0
GitLab Edition : ce
Backup ID      : 1699999999_2024_01_01_16.7.0
Script Version : 2.1.0
GitLab Archive : 1699999999_2024_01_01_16.7.0_gitlab_backup.tar
```

------------------------------------------------------------------------

## Recovery testing

It's recommended to periodically run `install.sh` against a recent backup on a clean VM and verify:
- GitLab services start successfully.
- Projects are accessible and repository cloning works.
- Users can authenticate.
- Uploaded files are available.

------------------------------------------------------------------------

## License

MIT. See [LICENSE](./LICENSE).
