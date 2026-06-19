# WSL Setup Log — 2026-06-19

Installed a native Ubuntu WSL distro alongside the existing `docker-desktop`
distro (which Docker Desktop uses as its backend). No reboot, no Windows
feature changes — WSL2 was already present.

## Starting state

```powershell
wsl --version
# WSL 2.3.26.0 / Kernel 5.15.167.4-1 / Windows 10.0.26200.8655

wsl --list --verbose
#   NAME              STATE     VERSION
# * docker-desktop    Running   2
```

## Commands run

```powershell
# 1. Install Ubuntu 24.04 LTS without auto-launching first-run setup
wsl --install -d Ubuntu --no-launch

# 2. Confirm the appx landed
Get-AppxPackage -Name "*Ubuntu*" | Select-Object Name, PackageFullName
# CanonicalGroupLimited.Ubuntu_2404.1.68.0_x64__79rhkp1fndgsc

# 3. Launch first-run setup in its own console window
#    (interactive — created UNIX user "bert" + password)
Start-Process -FilePath "ubuntu.exe" -WorkingDirectory "$env:USERPROFILE"

# 4. Verify registration and make Ubuntu the default distro
wsl --list --verbose
wsl --set-default Ubuntu
```

## Verification

```powershell
wsl -d Ubuntu -- bash -lc "lsb_release -a; uname -r; whoami"
# Ubuntu 24.04.1 LTS (Noble Numbat)
# 5.15.167.4-microsoft-standard-WSL2
# bert
```

## Final state

```
  NAME              STATE     VERSION
* Ubuntu            Running   2
  docker-desktop    Running   2
```

Typing `wsl` in any terminal now opens Ubuntu. Docker still uses
`docker-desktop` internally, unaffected by the default change.

## Pending (not yet run — interactive sudo)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git build-essential
```

## Handy references

- Open Ubuntu: `wsl` or `ubuntu` from any terminal, or Start menu → "Ubuntu"
- This repo from Ubuntu: `/mnt/c/Users/Bert/Documents/Mustry/Ignition/CICD`
- Switch default back to Docker's distro: `wsl --set-default docker-desktop`
- Cleanly remove Ubuntu later: `wsl --unregister Ubuntu`
  (does **not** affect Docker)
