# How the GitLab setup works

An overview of every piece involved in running and backing up
`gitlab.example.com`: where it runs, how traffic reaches it, how it's backed
up, and which document to use when something needs rebuilding.

| I need to… | Use |
|---|---|
| Understand the setup | this document |
| Rebuild GitLab on a fresh VM from the NAS backup | [rebuild-from-scratch.md](rebuild-from-scratch.md) |
| Format / reinstall the Windows PC and bring the VM back | [host-reinstall.md](host-reinstall.md) |
| Script usage, config and archive format | [../README.md](../README.md) |
| History: why/how it moved from VirtualBox to Hyper-V | [migrate-virtualbox-to-hyperv.md](migrate-virtualbox-to-hyperv.md) |

------------------------------------------------------------------------

## The big picture

```text
                       Internet
                          │  gitlab.example.com → 203.0.113.100 (public DNS)
                          ▼
                    Router 192.168.1.1
                          │
  LAN clients ── DNS ──►  Pi-hole + Caddy  192.168.1.130  (Debian)
       │                  │   • Pi-hole: gitlab.example.com → 192.168.1.130
       │                  │   • Caddy: HTTPS reverse proxy → 192.168.1.140:443
       │                  ▼
       │   git over SSH   ┌──────────────────────────────────────────────┐
       └─────────────────►│ HOSTPC  192.168.1.110  (Windows 11 Pro)      │
         (straight to     │  Hyper-V ── External switch (I225-V NIC)     │
          .140, see below)│    └─ VM "gitlab"  192.168.1.140             │
                          │         Ubuntu 24.04 + GitLab Omnibus CE     │
                          │  Docker Desktop / WSL2 (same hypervisor)     │
                          └──────────────────────┬───────────────────────┘
                                                 │ CIFS, daily + on boot
                                                 ▼
                                     NAS 192.168.1.120  //Backup/Gitlab
```

------------------------------------------------------------------------

## Network and name resolution

| Host | IP | Role |
|---|---|---|
| Router | `192.168.1.1` | Gateway; secondary DNS |
| Pi-hole + Caddy (Debian) | `192.168.1.130` | LAN DNS (ad-blocking), HTTPS reverse proxy for GitLab |
| HOSTPC (Windows host) | `192.168.1.110` | Runs Hyper-V and the GitLab VM |
| GitLab VM | `192.168.1.140` | GitLab itself |
| NAS | `192.168.1.120` | Backup storage |

**Web (HTTPS):** on the LAN, Pi-hole resolves `gitlab.example.com` to
`192.168.1.130`; Caddy there proxies to GitLab's own nginx on
`192.168.1.140:443`. From the internet, public DNS gives `203.0.113.100`
(the router's public IP).

**Git over SSH needs an override.** Caddy only proxies HTTP(S). Port 22 on
`192.168.1.130` is that Debian box's own `sshd`, not GitLab — connecting there
asks for a password, which GitLab never does. Every machine that uses
`git@gitlab.example.com` needs this in `~/.ssh/config`:

```text
Host gitlab.example.com
    HostName 192.168.1.140
    User git
```

On the GitLab VM itself, `HostName` is `127.0.0.1` (see
[The scripts on the VM](#the-scripts-on-the-vm)).

------------------------------------------------------------------------

## The Windows host (HOSTPC)

- **Windows 11 Pro** with **Hyper-V** enabled.
- **Virtual switch `External`** is bound to the physical `Ethernet` adapter
  (Intel I225-V) and shared with the host. The host's own network config
  therefore lives on the **`vEthernet (External)`** adapter: static
  `192.168.1.110/24`, gateway `192.168.1.1`, DNS `192.168.1.130`.
- **Docker Desktop** (WSL2) runs alongside. WSL2 and Hyper-V share the same
  Windows hypervisor, so they coexist safely.

**Why not VirtualBox:** WSL2/Docker Desktop turns on the Windows hypervisor,
which forces VirtualBox to run on top of it. That combination crashed the host
almost daily (bugcheck `0x00020001 HYPERVISOR_ERROR`) until the VM was moved to
Hyper-V on 2026-10-06.

------------------------------------------------------------------------

## The GitLab VM

| Setting | Value |
|---|---|
| Hyper-V name | `gitlab` (Generation 1 — converted from VirtualBox) |
| vCPUs / RAM | 4 / 8 GB **static** (GitLab dislikes dynamic memory) |
| Disk | `C:\Hyper-V\gitlab\gitlab.vhdx`, dynamic, 256 GB max, LVM inside |
| Network | `External` switch, static MAC `08:00:27:FA:9E:38` |
| Start / stop | Starts **30 s after Windows boots — no login needed**; shut down cleanly when Windows shuts down |
| Checkpoints | Automatic checkpoints off |
| OS | Ubuntu Server 24.04 LTS, hostname `gitlab`, user `admin` |
| IP | static `192.168.1.140/24` on `eth0` (`/etc/netplan/*.yaml`), DNS `192.168.1.130, 192.168.1.1` |
| GitLab | Omnibus **CE**, version in `/opt/gitlab/embedded/service/gitlab-rails/VERSION` (19.4.1 as of 2026-10-06) |
| TLS | Let's Encrypt, managed by GitLab, files in `/etc/gitlab/ssl/` |

Day-to-day checks (on the VM):

```bash
sudo gitlab-ctl status
```

```bash
sudo gitlab-rake gitlab:check SANITIZE=true
```

From Windows (Administrator PowerShell):

```powershell
Get-VM -Name "gitlab" | Select Name, State, Uptime, AutomaticStartAction, AutomaticStopAction
```

------------------------------------------------------------------------

## Backups

### What runs, and when

A systemd timer on the VM runs `backup.sh` **5 minutes after every boot** and
**daily at 02:00** (`Persistent=true`: a missed 02:00 runs as soon as the VM is
back up).

```text
gitlab-backup.timer ──► gitlab-backup.service ──► /home/admin/gitlab_backup/backup.sh
```

```bash
systemctl list-timers gitlab-backup.timer
```

### What `backup.sh` does

1. Waits for PostgreSQL, then runs `gitlab-backup create`.
2. Packs into one `gitlab_backup_<timestamp>.tar.gz`:
   - the GitLab data backup (`<backup-id>_gitlab_backup.tar`)
   - `gitlab.rb` and `gitlab-secrets.json`
   - SSH host keys (`/etc/ssh/ssh_host_*`) — so a rebuilt VM keeps the same
     SSH identity and git clients see no warning
   - `/etc/gitlab/ssl` and `/etc/gitlab/trusted-certs` (if non-empty)
   - `backup_info.txt` — GitLab version/edition, backup ID, hostname, date
3. Verifies the archive and copies it to the NAS; if the NAS is unreachable it
   stays in `/mnt/shared/backup/gitlab/local` and goes up on the next run.
4. Deletes archives and logs older than `RETENTION_DAYS` (5).

The archive contains private keys and `gitlab-secrets.json` — treat the NAS
share as secret.

### Where things are

| What | Where |
|---|---|
| Archives | NAS `//192.168.1.120/Backup/Gitlab`, mounted on the VM at `/mnt/sources/nas/backup/gitlab` |
| Logs | `/mnt/sources/nas/backup/gitlab/logs/` (falls back to `/mnt/shared/backup/gitlab/logs` if the NAS is down) |
| NAS mount | `/etc/fstab` CIFS entry with `x-systemd.automount` — mounts on first access |
| NAS credentials | `/root/.smbcredentials` (mode 600) |
| Config | `~/gitlab_backup/config/backup.conf` |

Check the latest run:

```bash
tail -3 "$(ls -t /mnt/sources/nas/backup/gitlab/logs/*.log | head -1)"
```

Run one by hand:

```bash
cd ~/gitlab_backup && sudo ./backup.sh
```

### Restoring

`install.sh` reads the GitLab version from a backup, installs **exactly that
version** on a fresh Ubuntu, and hands off to `restore.sh`, which restores data,
config, secrets, certs and SSH host keys. GitLab can only restore a backup into
the same version it was made with — this is why the version is recorded.
Full walkthrough: [rebuild-from-scratch.md](rebuild-from-scratch.md).

------------------------------------------------------------------------

## The scripts on the VM

`~/gitlab_backup` is a git clone of `scripts/gitlab_backup` from this GitLab.
It pulls with a **read-only deploy key**:

- key: `~/.ssh/gitlab_backup_deploy` (registered under *scripts/gitlab_backup →
  Settings → Repository → Deploy keys*, write access off)
- `~/.ssh/config` on the VM:

  ```text
  Host gitlab.example.com
      HostName 127.0.0.1
      User git
      IdentityFile ~/.ssh/gitlab_backup_deploy
      IdentitiesOnly yes
  ```

Updating the scripts after a push from Windows:

```bash
cd ~/gitlab_backup && git pull
```

The scripts are stored executable (`100755`) with LF line endings
(`.gitattributes`), so a fresh clone runs as-is. When committing from Windows,
new scripts need `git update-index --chmod=+x <file>` — Windows can't set the
bit itself.

------------------------------------------------------------------------

## Things that have bitten us

| Symptom | Cause | Fix |
|---|---|---|
| Host reboots, `HYPERVISOR_ERROR` in event log | VirtualBox + WSL2/Docker Desktop | Use Hyper-V for VMs (done) |
| Host loses internet after creating a Hyper-V External switch | Static DNS servers not carried to `vEthernet (External)` | `Set-DnsClientServerAddress -InterfaceAlias "vEthernet (External)" -ServerAddresses 192.168.1.130` |
| VM has no network after moving hypervisors | NIC renamed (`enp0s3` → `eth0`), netplan still uses the old name | Edit `/etc/netplan/*.yaml`, `sudo netplan apply` |
| `git@gitlab.example.com` asks for a password | SSH went to `.130` (Caddy/Pi-hole box) | `~/.ssh/config` `HostName` override |
| Backup timer fails with *Permission denied* | Scripts committed from Windows without the executable bit | `chmod +x *.sh`; fix in git with `git update-index --chmod=+x` |
| No new backups on a long-running VM | Timer only had `OnBootSec` | `OnCalendar` daily (done) |
