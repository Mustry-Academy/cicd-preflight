# Setting up WSL2 for the course (Windows only)

If you are on macOS or Linux, you can skip this page.

You need a real Linux distro in WSL2. Docker Desktop installs its own internal
`docker-desktop` distro, but that one is not meant for you to work in — install
Ubuntu alongside it.

## 1. Install Ubuntu

From PowerShell:

```powershell
wsl --version          # confirm WSL 2 is present
wsl --install -d Ubuntu
```

The first launch asks you to create a UNIX username and password. This user is
separate from your Windows account, which matters later.

Make Ubuntu your default distro so plain `wsl` opens it:

```powershell
wsl --set-default Ubuntu
```

Verify:

```powershell
wsl --list --verbose
# NAME              STATE     VERSION
# Ubuntu            Running   2
# docker-desktop    Running   2
```

## 2. Enable Docker Desktop's WSL integration

Docker Desktop → Settings → Resources → **WSL integration** → enable your Ubuntu
distro → Apply & restart.

Then, inside Ubuntu, confirm Docker works **without `sudo`**:

```bash
docker run --rm hello-world
```

If that needs `sudo`, integration is not set up correctly. Fix it there rather
than working around it with `sudo` — see step 4.

## 3. Update Ubuntu and install the basics

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git build-essential
```

Installing packages is one of the few legitimate uses of `sudo` in this course.

## 4. The rule that decides whether the labs work

**Keep every course repo in your Linux home (`~/…`), never on your Windows drive
(`/mnt/c/…`).**

```bash
mkdir -p ~/mustry-academy && cd ~/mustry-academy
git clone <repo-url>
cd <repo>
code .            # opens VS Code connected to WSL
```

Check where you are at any time with `pwd`. It must not start with `/mnt/`.

Under `/mnt/c` you are looking at your Windows disk through a translation layer.
File ownership there is decided by Windows ACLs, not by your WSL user. Your
Windows user, your WSL user and the Ignition container's user are three
different identities, so:

- `chown` and `chmod` appear to succeed but do not stick,
- Docker bind mounts lose permission bits,
- you hit "permission denied" on your own project files,
- and reaching for `sudo` leaves root-owned files that cause the *next* error.

Running WSL as a Windows administrator makes the symptom go away by sidestepping
the ACL entirely. It is not a fix, and it makes each later lab worse. The lab
setup scripts refuse to run from `/mnt/c`, and none of them ever need `sudo`.

## 5. Optional: metadata on Windows drives

Only relevant if you keep *other* projects on `/mnt/c`. It lets Windows-drive
paths store Linux ownership at all:

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[automount]
enabled = true
options = "metadata,umask=022,fmask=011"
EOF
```

Then, from PowerShell, `wsl --shutdown` and reopen your terminal.

## Handy references

- Open Ubuntu: `wsl` or `ubuntu` from any terminal, or Start menu → "Ubuntu"
- Switch default back to Docker's distro: `wsl --set-default docker-desktop`
- Cleanly remove Ubuntu later: `wsl --unregister Ubuntu` (does **not** affect Docker)
- RAM and disk for WSL2 are configured in `C:\Users\<you>\.wslconfig`
