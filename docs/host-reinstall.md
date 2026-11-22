# Reinstalling Windows on HOSTPC without losing GitLab

The GitLab VM lives on HOSTPC's C: drive (`C:\Hyper-V\gitlab\`), so formatting
the PC wipes it. This is the procedure for exporting the VM before the format
and importing it afterwards. GitLab comes back exactly as it was: same IP, same
SSH host keys, same backup timer, no restore needed.

GitLab is **down** from the export (Part 1, step 3) until the import
(Part 2, step 5).

If the export is lost or won't import, fall back to
[rebuild-from-scratch.md](rebuild-from-scratch.md), which rebuilds from the NAS
backup. For how the pieces fit together, see [how-it-works.md](how-it-works.md).

------------------------------------------------------------------------

## Part 1: before the format

### 1. Pick a safe drive

Everything below is copied to a drive that is **not** being formatted. The
examples use `F:` — change it if F: is being wiped too. You need roughly the
VM disk's current size free (check `C:\Hyper-V\gitlab\gitlab.vhdx`) plus a few
GB.

### 2. Take a fresh GitLab backup

A safety net in case the export doesn't import. On the VM:

```bash
cd ~/gitlab_backup && sudo ./backup.sh
```

Confirm it ends with `Backup completed successfully` and the archive is on the
NAS.

### 3. Shut down and export the VM

Administrator PowerShell:

```powershell
Stop-VM -Name "gitlab"
```

```powershell
Export-VM -Name "gitlab" -Path "F:\VM-Export"
```

This creates `F:\VM-Export\gitlab\` with the VM's configuration
(`Virtual Machines\*.vmcx`) and its disk (`Virtual Hard Disks\gitlab.vhdx`).
The settings — CPUs, static memory, static MAC, auto-start — are included.

GUI: Hyper-V Manager → right-click `gitlab` → **Export…** → choose the folder.

Check it's all there:

```powershell
Get-ChildItem "F:\VM-Export\gitlab" -Recurse -File | Select FullName, @{n='GB';e={[math]::Round($_.Length/1GB,1)}}
```

### 4. Save the host's own settings

Note the host's network settings (you'll re-enter them in Part 2):

```powershell
Get-NetIPConfiguration -InterfaceAlias "vEthernet (External)"
```

Expected: `192.168.1.110/24`, gateway `192.168.1.1`, DNS `192.168.1.130`.

Copy these folders and files from `C:\Users\<you>\` to the safe drive:

| What | Why |
|---|---|
| `.ssh\` | Your SSH keys **and** `config`, which contains the `gitlab.example.com → 192.168.1.140` override that git over SSH depends on |
| `.gitconfig` | Git name/email and settings |
| `.wslconfig` | WSL2/Docker memory limits (if you created one) |

```powershell
New-Item -ItemType Directory -Force "F:\HOSTPC-backup"
```

```powershell
Copy-Item -Recurse "$env:USERPROFILE\.ssh" "F:\HOSTPC-backup\"
```

```powershell
Copy-Item "$env:USERPROFILE\.gitconfig", "$env:USERPROFILE\.wslconfig" "F:\HOSTPC-backup\" -ErrorAction SilentlyContinue
```

If **D:** is being formatted as well, also copy `D:\repos\` (or make sure
everything in it is pushed).

Also check Docker Desktop for any containers or volumes you care about — they
live inside WSL2 on C: and are not covered here.

------------------------------------------------------------------------

## Part 2: after reinstalling Windows

Use Administrator PowerShell throughout.

### 1. Enable Hyper-V (reboot required)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
```

Do **not** install VirtualBox on this host again — it's what crashed it.

### 2. Create the `External` switch

The name must be exactly `External`; the exported VM expects it.

```powershell
Get-NetAdapter | Select Name, InterfaceDescription, Status
```

```powershell
New-VMSwitch -Name "External" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

Use the name of the Intel I225-V adapter in place of `Ethernet` if it differs.
Host networking drops for a few seconds.

### 3. Give the host its static IP and Pi-hole DNS

The host's network config now lives on `vEthernet (External)`. On a fresh
Windows it will be on DHCP; set it back to the old values:

```powershell
Set-NetIPInterface -InterfaceAlias "vEthernet (External)" -Dhcp Disabled
```

```powershell
New-NetIPAddress -InterfaceAlias "vEthernet (External)" -IPAddress 192.168.1.110 -PrefixLength 24 -DefaultGateway 192.168.1.1
```

```powershell
Set-DnsClientServerAddress -InterfaceAlias "vEthernet (External)" -ServerAddresses 192.168.1.130
```

```powershell
ipconfig /flushdns
```

```powershell
nslookup google.com
```

`nslookup` should show `Server: … 192.168.1.130` and an answer.

GUI alternative: *Settings → Network & internet → Ethernet* (pick
`vEthernet (External)`) → *IP assignment* **Manual** and *DNS server
assignment* **Manual**.

### 4. Put the saved files back

```powershell
Copy-Item -Recurse "F:\HOSTPC-backup\.ssh" "$env:USERPROFILE\" -Force
```

```powershell
Copy-Item "F:\HOSTPC-backup\.gitconfig", "F:\HOSTPC-backup\.wslconfig" "$env:USERPROFILE\" -ErrorAction SilentlyContinue
```

### 5. Import the VM

```powershell
$vmcx = Get-ChildItem "F:\VM-Export\gitlab\Virtual Machines\*.vmcx" | Select -First 1
```

```powershell
Import-VM -Path $vmcx.FullName -Copy -VirtualMachinePath "C:\Hyper-V\gitlab" -VhdDestinationPath "C:\Hyper-V\gitlab"
```

`-Copy` copies the files to C: and leaves the export untouched as a fallback;
it keeps the VM's original ID.

GUI: Hyper-V Manager → **Import Virtual Machine…** → select
`F:\VM-Export\gitlab` → **Restore the virtual machine (use the existing unique
ID)** → store the files under `C:\Hyper-V\gitlab`.

If the import complains about the network, the switch isn't named exactly
`External` — rename it, or connect the VM's adapter to the right switch in
*Settings → Network Adapter*.

Check the settings came across, then start it:

```powershell
Get-VM -Name "gitlab" | Select Name, State, ProcessorCount, MemoryStartup, DynamicMemoryEnabled, AutomaticStartAction, AutomaticStopAction
```

Expected: 4 CPUs, 8 GB, dynamic memory `False`, start action `Start`, stop
action `ShutDown`.

```powershell
Start-VM -Name "gitlab"
```

### 6. Verify

On the VM (`ssh admin@192.168.1.140`):

```bash
sudo gitlab-ctl status
```

```bash
findmnt /mnt/sources/nas/backup/gitlab
```

```bash
systemctl list-timers gitlab-backup.timer
```

From Windows: open `https://gitlab.example.com`, then a `git pull` / `git push`
in `D:\repos\gitlab-vm-backup` to prove SSH (and the restored `.ssh\config`)
works.

If SSH refuses your private key with *"Permissions … are too open"*, reset the
key file's permissions to just your user:

```powershell
icacls "$env:USERPROFILE\.ssh\id_rsa" /inheritance:r /grant:r "$($env:USERNAME):F"
```

### 7. Reinstall the rest

Docker Desktop and any other tools. Docker Desktop and Hyper-V coexist; the
order doesn't matter.

### 8. Clean up (after a week)

Once the host has been stable and backups have kept arriving on the NAS, delete
`F:\VM-Export` and `F:\HOSTPC-backup`.
