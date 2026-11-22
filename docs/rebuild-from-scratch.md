# Rebuild GitLab from scratch (fresh Ubuntu + restore)

Build a brand-new GitLab VM on Hyper-V and restore it from the latest NAS
backup: a new VM, a fresh Ubuntu, then `install.sh` installs the exact GitLab
version recorded in the backup and restores everything into it.

Use this when:
- the `gitlab` VM is broken beyond repair, or
- the Windows host was reinstalled and there is **no VM export** to import
  (if there is one, [host-reinstall.md](host-reinstall.md) is quicker).

On a freshly installed Windows host, first do *Part 2, steps 1–3* of
[host-reinstall.md](host-reinstall.md) (enable Hyper-V, create the `External`
switch, fix DNS), then start here at step 2.

For how the pieces fit together, see [how-it-works.md](how-it-works.md).

Expected time: ~1 hour (most of it is the Ubuntu install and the GitLab package
download).

## Current production values

| Item | Value |
|---|---|
| Hyper-V host | HOSTPC (`192.168.1.110`) |
| Hyper-V VM name | `gitlab` |
| VM disk | `C:\Hyper-V\gitlab\gitlab.vhdx` |
| vCPUs / RAM | 4 / 8 GB static |
| Virtual switch | `External` (bound to the I225-V `Ethernet` adapter) |
| Guest OS | Ubuntu Server 24.04 LTS |
| Hostname / user | `gitlab` / `admin` |
| IP | `192.168.1.140/24`, gateway `192.168.1.1` — static, set in netplan |
| DNS | `192.168.1.130` (Pi-hole), `192.168.1.1` |
| GitLab | `gitlab.example.com`, CE, version recorded in each backup's `backup_info.txt` |
| Backups | NAS `//192.168.1.120/Backup/Gitlab` → mounted at `/mnt/sources/nas/backup/gitlab` |
| Backup schedule | systemd `gitlab-backup.timer`: 5 min after boot + daily 02:00 |

------------------------------------------------------------------------

## Before a disaster: things that must exist outside GitLab

This repo is hosted **on the GitLab it restores**
(`git@gitlab.example.com:tools/gitlab-vm-backup.git`), so you can't clone it
when GitLab is down. Make sure you have:

- [ ] A copy of this repo off the VM — `D:\repos\gitlab-vm-backup` on HOSTPC
      (keep it pulled), ideally also a copy on the NAS.
- [ ] The NAS SMB username/password (`install.sh` prompts for them).
- [ ] An Ubuntu Server 24.04 ISO, or internet access to download one.
- [ ] Recent archives on the NAS — check
      `/mnt/sources/nas/backup/gitlab/` or the share from Windows.

------------------------------------------------------------------------

## 1. Take the broken VM out of the way (skip if there is none)

Keep it (for anything you can still copy off it) but make sure it can't come
back up on `192.168.1.140` and fight the new one. Administrator PowerShell:

```powershell
Stop-VM -Name "gitlab" -TurnOff
```

```powershell
Set-VM -Name "gitlab" -AutomaticStartAction Nothing
```

```powershell
Rename-VM -Name "gitlab" -NewName "gitlab-broken"
```

Delete `gitlab-broken` and its disk once the new VM is restored and verified.

## 2. Create the new VM

A fresh install can use **Generation 2** (UEFI). Ubuntu needs the Microsoft
UEFI CA Secure Boot template.

```powershell
New-Item -ItemType Directory -Force "C:\Hyper-V\gitlab-new"
```

```powershell
New-VM -Name "gitlab" -Generation 2 -MemoryStartupBytes 8GB -NewVHDPath "C:\Hyper-V\gitlab-new\gitlab.vhdx" -NewVHDSizeBytes 256GB -SwitchName "External" -Path "C:\Hyper-V\gitlab-new"
```

```powershell
Set-VMProcessor -VMName "gitlab" -Count 4
```

```powershell
Set-VMMemory -VMName "gitlab" -DynamicMemoryEnabled $false
```

```powershell
Set-VMFirmware -VMName "gitlab" -SecureBootTemplate MicrosoftUEFICertificateAuthority
```

```powershell
Add-VMDvdDrive -VMName "gitlab" -Path "C:\path\to\ubuntu-24.04-live-server-amd64.iso"
```

```powershell
Set-VMFirmware -VMName "gitlab" -FirstBootDevice (Get-VMDvdDrive -VMName "gitlab")
```

```powershell
Set-VM -Name "gitlab" -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false
```

```powershell
Start-VM -Name "gitlab"
```

```powershell
vmconnect localhost gitlab
```

GUI alternative: Hyper-V Manager → *New → Virtual Machine…* → Generation 2,
8192 MB with Dynamic Memory unticked, `External` switch, new 256 GB disk,
install from the ISO. Then *Settings → Security* → template *Microsoft UEFI
Certificate Authority*, *Processor* → 4, *Automatic Start/Stop Action* as above.

## 3. Install Ubuntu Server 24.04

In the installer:

- **Network** → edit the interface → IPv4 *Manual*:
  subnet `192.168.1.0/24`, address `192.168.1.140`, gateway `192.168.1.1`,
  name servers `192.168.1.130,192.168.1.1`.
- **Storage** → default (whole disk, LVM). The installer only gives
  `ubuntu-lv` ~100 GB by default; edit it to use the full volume group.
- **Profile** → name `admin`, server name **`gitlab`**, user `admin`.
- **SSH** → tick *Install OpenSSH server*.
- **Snaps** → none.

Reboot when done. The installer usually ejects the ISO; if the VM boots back
into the installer, remove it:

```powershell
Get-VMDvdDrive -VMName "gitlab" | Remove-VMDvdDrive
```

Inside the VM, install the Hyper-V integration daemons:

```bash
sudo apt update && sudo apt install -y linux-tools-virtual linux-cloud-tools-virtual
```

## 4. Copy this repo onto the VM

GitLab is down, so copy it from HOSTPC instead of cloning (PowerShell on
HOSTPC):

```powershell
scp -r D:\repos\gitlab-vm-backup admin@192.168.1.140:~/
```

The scripts are stored with LF line endings (`.gitattributes`), so they run
as-is. `scp` from Windows drops the executable bit, so on the VM:

```bash
chmod +x ~/gitlab_backup/*.sh
```

Check `~/gitlab_backup/config/backup.conf` — the NAS host/share and paths
should already be correct.

## 5. Install the matching GitLab version and restore

```bash
cd ~/gitlab_backup
```

```bash
sudo ./install.sh
```

It will:
1. Mount the NAS share — **prompts for the SMB username and password** the
   first time, then writes `/root/.smbcredentials` and the `/etc/fstab` entry.
2. List the backup archives — pick the newest one (top of the list).
3. Read the GitLab version/edition from that backup, add GitLab's apt repo,
   install that exact version and `apt-mark hold` it.
4. Hand off to `restore.sh` — **type `YES`** when asked.
5. Restore the data, `gitlab.rb`, `gitlab-secrets.json`, TLS certs and SSH
   host keys, then reconfigure and restart.

Logs go to the NAS under `logs/` (or locally if the NAS mount failed).

## 6. Re-create the backup schedule

The timer isn't part of the backup, so set it up again — unit files are in
the [README](../README.md#creating-a-backup) (use `/home/admin/gitlab_backup` for the
paths), then:

```bash
sudo systemctl daemon-reload
```

```bash
sudo systemctl enable --now gitlab-backup.timer
```

```bash
systemctl list-timers gitlab-backup.timer
```

## 7. Verify

```bash
sudo gitlab-ctl status
```

```bash
sudo gitlab-rake gitlab:check SANITIZE=true
```

```bash
findmnt /mnt/sources/nas/backup/gitlab
```

Then from a workstation: web UI login, `git clone` / `git push` over SSH.

**SSH host keys:** archives from `backup.sh` 2.1.0+ carry the old VM's SSH host
keys and `restore.sh` puts them back, so git clients connect without warnings.

The one exception is *your own* SSH session to `192.168.1.140`: you connected
during the rebuild while the VM still had the fresh install's keys, so your
next `ssh admin@192.168.1.140` warns once. Clear it with:

```powershell
ssh-keygen -R 192.168.1.140
```

If the archive predates 2.1.0 (`Script Version` in `backup_info.txt`), the
restore keeps the new VM's keys and every git user has to run
`ssh-keygen -R gitlab.example.com` once.

Switch the `scp`'d copy of this repo back to a real clone so it can
`git pull` again. `gitlab.example.com` resolves to `192.168.1.130` (the
reverse proxy), not this VM, so SSH needs an override pointing at itself, and
a read-only **deploy key**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gitlab_backup_deploy -N "" -C "gitlab-vm deploy key (gitlab_backup)"
```

```bash
cat >> ~/.ssh/config <<'EOF'
Host gitlab.example.com
    HostName 127.0.0.1
    User git
    IdentityFile ~/.ssh/gitlab_backup_deploy
    IdentitiesOnly yes
EOF
```

Add `~/.ssh/gitlab_backup_deploy.pub` under *scripts/gitlab_backup → Settings →
Repository → Deploy keys* (write access **off**), and delete the old VM's
deploy key there. Then:

```bash
mv ~/gitlab_backup ~/gitlab_backup.scp && git clone git@gitlab.example.com:tools/gitlab-vm-backup.git ~/gitlab_backup
```

Finally, take a fresh backup so the NAS has one from the rebuilt VM:

```bash
sudo ./backup.sh
```

------------------------------------------------------------------------

## What the backup does *not* include

| Item | Effect after a rebuild | Handled by |
|---|---|---|
| systemd timer/service units | No scheduled backups | Step 6 |
| Netplan / static IP | — | Ubuntu installer (step 3) |
| NAS SMB credentials | — | `install.sh` prompts (step 5) |
