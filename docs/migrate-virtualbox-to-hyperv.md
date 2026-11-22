# Migrating the GitLab VM from VirtualBox to Hyper-V

> **Completed 2026-10-06.** Kept as a record of how the VM was moved and why.
> For the current setup see [how-it-works.md](how-it-works.md); to rebuild see
> [rebuild-from-scratch.md](rebuild-from-scratch.md) or
> [host-reinstall.md](host-reinstall.md).

## Why

Running VirtualBox VMs alongside Docker Desktop (WSL2) on the same Windows host
crashed the host repeatedly — bugcheck `0x00020001` (`HYPERVISOR_ERROR`), ~30
unexpected reboots between 2026-09-20 and 2026-10-06. Memory was not the cause
(63 GB total, ~44 GB free).

WSL2 turns on the Windows hypervisor, which forces VirtualBox to run on top of
it instead of using VT-x directly — a known unstable combination. Hyper-V and
WSL2 share the same hypervisor by design, so moving the VM to Hyper-V removes
the conflict.

## Source VM (VirtualBox)

| Setting | Gitlab_2 (live) | gitlab (older) |
|---|---|---|
| Memory | 8 GB | 4 GB |
| CPUs | 4 | 3 |
| Firmware | BIOS → Hyper-V **Generation 1** | BIOS → Generation 1 |
| Disk | `C:\Users\<you>\VirtualBox VMs\Gitlab_2\Gitlab_2.vdi` (256 GB max) | `C:\Users\<you>\VirtualBox VMs\gitlab\gitlab.vdi` (256 GB max) |
| NIC | Bridged to Intel I225-V | Bridged to Intel I225-V |
| MAC | `080027FA9E38` | `080027A9B6E1` |

The steps below migrate **Gitlab_2** and name it **gitlab** in Hyper-V (the old
VirtualBox `gitlab` VM is a spare and gets retired with VirtualBox). To migrate
the old one instead, substitute its disk path, MAC, memory and CPU count.

Run all Windows commands in an **Administrator** PowerShell. Each step lists the
Hyper-V Manager (GUI) equivalent where one exists.

------------------------------------------------------------------------

## 0. Fresh backup first

Boot the VM in VirtualBox one last time:

```bash
sudo ./backup.sh
```

Then `sudo poweroff` and **close VirtualBox**. The original `.vdi` is never
modified — it stays as the rollback path.

## 1. Enable Hyper-V (reboot required)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
```

GUI: *Turn Windows features on or off* → tick **Hyper-V** (both sub-items).

WSL2 and Docker Desktop keep working.

## 2. External virtual switch (Hyper-V's "bridged")

```powershell
Get-NetAdapter | Select Name, InterfaceDescription, Status
```

```powershell
New-VMSwitch -Name "External" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

Replace `Ethernet` with the I225-V adapter's name. Host networking drops for a
few seconds.

**The host's static IP config moves to the new `vEthernet (External)` adapter,
but its DNS servers can get lost on the way** (this happened on HOSTPC — the
internet stopped working until DNS was set again). Note the current settings
*before* creating the switch:

```powershell
Get-NetIPConfiguration -InterfaceAlias "Ethernet"
```

Afterwards, if name resolution fails, re-apply them to the new adapter
(HOSTPC: `192.168.1.110/24`, gateway `192.168.1.1`, DNS = Pi-hole
`192.168.1.130`):

```powershell
Set-DnsClientServerAddress -InterfaceAlias "vEthernet (External)" -ServerAddresses 192.168.1.130
```

```powershell
ipconfig /flushdns
```

GUI: Hyper-V Manager → *Virtual Switch Manager…* → New virtual network switch →
**External** → pick the I225-V → tick *Allow management operating system to
share this network adapter*.

## 3. Convert the disk

```powershell
New-Item -ItemType Directory -Force "C:\Hyper-V\gitlab"
```

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" clonemedium disk "C:\Users\<you>\VirtualBox VMs\Gitlab_2\Gitlab_2.vdi" "C:\Hyper-V\gitlab\gitlab.vhd" --format VHD
```

```powershell
Convert-VHD -Path "C:\Hyper-V\gitlab\gitlab.vhd" -DestinationPath "C:\Hyper-V\gitlab\gitlab.vhdx" -VHDType Dynamic
```

GUI: the VDI → VHD step has no GUI (VBoxManage only). VHD → VHDX: Hyper-V
Manager → *Edit Disk…* → pick the `.vhd` → **Convert** → VHDX, dynamically
expanding.

Delete the intermediate `.vhd` once the VM boots.

## 4. Create the VM

```powershell
New-VM -Name "gitlab" -Generation 1 -MemoryStartupBytes 8GB -VHDPath "C:\Hyper-V\gitlab\gitlab.vhdx" -SwitchName "External" -Path "C:\Hyper-V"
```

```powershell
Set-VMProcessor -VMName "gitlab" -Count 4
```

Static memory — GitLab (PostgreSQL/Puma) doesn't like the balloon driver taking
RAM back:

```powershell
Set-VMMemory -VMName "gitlab" -DynamicMemoryEnabled $false
```

Keep the old MAC so DHCP hands out the same IP:

```powershell
Set-VMNetworkAdapter -VMName "gitlab" -StaticMacAddress "080027FA9E38"
```

Start with Windows (no login needed), shut down cleanly with it:

```powershell
Set-VM -Name "gitlab" -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false
```

```powershell
Start-VM -Name "gitlab"
```

GUI: Hyper-V Manager → *New → Virtual Machine…* wizard: **Generation 1**,
8192 MB startup memory with *Use Dynamic Memory* **unticked**, connection
*External*, *Use an existing virtual hard disk* → the `.vhdx`. Then
VM → *Settings…*:
- *Processor* → 4 virtual processors
- *Network Adapter → Advanced Features* → **Static** MAC `08-00-27-FA-9E-38`
- *Automatic Start Action* → Always start automatically, 30 s delay
- *Automatic Stop Action* → Shut down the guest operating system
- *Checkpoints* → untick *Use automatic checkpoints*

Open the console with **Connect…** (or `vmconnect localhost gitlab`).

## 5. Fix networking inside Ubuntu

The NIC is now Hyper-V's synthetic adapter, so the interface renames from
`enp0s3` to `eth0`; netplan still references the old name and the VM will
likely boot with no network. From the console:

```bash
ip -br link
```

```bash
sudo nano /etc/netplan/*.yaml
```

Replace `enp0s3` with the name shown above, then:

```bash
sudo netplan apply
```

## 6. Guest cleanup

```bash
sudo apt purge -y 'virtualbox-guest-*'
```

```bash
sudo apt install -y linux-tools-virtual linux-cloud-tools-virtual
```

The second package provides the Hyper-V KVP/VSS daemons (IP shown in Hyper-V
Manager, clean host-initiated shutdown).

## 7. Verify

```bash
sudo gitlab-ctl status
```

```bash
sudo gitlab-rake gitlab:check SANITIZE=true
```

```bash
mount | grep cifs
```

Then from a workstation: web UI login, `git clone` over SSH, and one
`sudo ./backup.sh` run reaching the NAS.

## 8. Retire VirtualBox (after ~1 week stable)

- **Never boot the VirtualBox copy again** — same MAC and IP would collide.
- Check the host stays up: no new `HYPERVISOR_ERROR` bugchecks
  (Event Viewer → System → IDs 41 / 1001 / 6008).
- Uninstall VirtualBox; delete the old `.vdi` after a further grace period.
- Optional: cap WSL2/Docker memory with `C:\Users\<you>\.wslconfig`:

  ```ini
  [wsl2]
  memory=16GB
  ```

------------------------------------------------------------------------

## Troubleshooting

- **Stuck at an `initramfs` prompt** — `/etc/fstab` likely references a device
  name (`/dev/sda1`) instead of a UUID. Boot a live ISO, mount the root disk, and
  switch the entry to `UUID=` (from `blkid`).
- **No network after `netplan apply`** — confirm the VM is on the *External*
  switch and the static MAC is set; check `ip a` for a DHCP lease.
- **Rollback** — shut down the Hyper-V VM, reinstall/reopen VirtualBox, boot the
  untouched `.vdi`.
