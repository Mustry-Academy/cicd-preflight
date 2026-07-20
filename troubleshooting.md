# Troubleshooting the preflight

## "You are working on the Windows filesystem"

Your repo is somewhere under `/mnt/c/…` (or another Windows drive). Move it to your
Linux home and clone again there:

```bash
mkdir -p ~/mustry-academy && cd ~/mustry-academy
git clone https://github.com/mustry-academy/cicd-preflight.git
cd cicd-preflight
./scripts/preflight.sh
```

Check where you are at any time with `pwd` — it must **not** start with `/mnt/`.
Open the folder in VS Code from there with `code .`, which keeps the WSL connection.

**Why this is a hard failure, not a style preference.** On the Windows drive, file
ownership is decided by Windows ACLs rather than your WSL user. Your Windows user,
your WSL user and the Ignition container's user are three different identities, so
`chown`/`chmod` appear to succeed but do not stick, and Docker bind mounts lose
permission bits. You then hit "permission denied" on your own project files, reach
for `sudo`, and `sudo` leaves root-owned files that cause the *next* error. Running
WSL as a Windows administrator appears to fix it, but it only sidesteps the ACL and
makes each later lab worse. Working from the Linux side avoids all of it. The lab
setup scripts refuse to run from `/mnt/c` for this reason.

## "This script is running under sudo"

Run it as yourself, without `sudo`:

```bash
./scripts/preflight.sh
```

Nothing in this course needs root. Every file created under `sudo` is owned by root,
which is exactly what causes the permission errors `sudo` appears to solve. The only
legitimate uses of `sudo` are installing packages (`sudo apt install …`) and the
one-off repairs the lab setup scripts explicitly ask permission for.

If an earlier `sudo` run already left root-owned files behind, hand them back to
yourself:

```bash
sudo chown -R "$(id -u):$(id -g)" ~/mustry-academy
```

## Windows: "docker not found" or it works in CMD but not WSL

You must run the preflight from inside WSL2, not from CMD or Git Bash. In Docker Desktop → Settings → Resources → WSL Integration, enable integration for your WSL distro (typically Ubuntu).

## "Docker daemon is not running"

- **Windows / macOS:** open Docker Desktop and wait for the whale icon to stop animating
- **Linux:** `sudo systemctl start docker` (and `sudo systemctl enable docker` for auto-start)
- **Linux, "permission denied":** add yourself to the `docker` group with `sudo usermod -aG docker $USER`, then log out and back in

## "Could not pull inductiveautomation/ignition:8.3.6"

This is usually a network issue. Try:

```bash
curl -I https://hub.docker.com
docker pull hello-world
```

If those fail too, you're behind a corporate proxy. Configure Docker Desktop's proxy settings in Settings → Resources → Proxies, or set `HTTPS_PROXY` in your shell. If only the Ignition pull fails, your firewall is filtering Docker Hub content — talk to your IT team.

## "Gateway did not respond within 90s"

Two common causes (the preflight publishes the gateway on a Docker-assigned free port, so a busy port is no longer one of them):

1. **Docker has too little memory.** In Docker Desktop → Settings → Resources, allocate at least 4 GB RAM to Docker.
2. **First-pull slowness.** Try `docker logs mustry-preflight-gateway` (if the container is still around) or just re-run the preflight; subsequent runs are much faster.

## "gh is not authenticated"

```bash
gh auth login
```

Choose GitHub.com → HTTPS → "Login with a web browser" → follow the prompts. The script will pop a one-time code; enter it in the browser.

## VS Code "code" command not found

This isn't strictly required, but it makes the labs easier. To add it:

- **Mac:** open VS Code → `Cmd+Shift+P` → "Shell Command: Install 'code' command in PATH"
- **Windows / Linux:** it's typically already on PATH after a default install. Restart your shell first.

## "Total RAM looks low" or "Free disk space looks low"

Both are **warnings, not failures**. Ignition + Docker run comfortably with **≥ 8 GB RAM** and
**≥ 20 GB free disk**; below that, the gateway container may be slow or get OOM-killed.

**On WSL2 (Windows), these numbers are measured inside WSL2, not for your whole Windows PC** —
which is what matters, because Docker keeps its images, volumes and containers there. To give
WSL2 more RAM, create or edit `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=12GB
```

Then run `wsl --shutdown` in PowerShell and restart your distro. For disk, prune unused Docker
data with `docker system prune -a` and remove old volumes you no longer need.

## "Ignition Designer Launcher not detected"

This is a **warning, not a failure** — the script looks for the Launcher in its usual install
locations and the `~/.ignition/clientlauncher-data` config folder, but detection is best-effort
(the Launcher isn't on your PATH). If you already have it, you can safely ignore the warning.

If you don't have it yet, install it from your gateway: open the gateway web page → **Downloads**
→ **Designer Launcher**, download for your OS, and run it once. On Windows the Launcher installs
on the Windows host (not inside WSL2) — the preflight probes `/mnt/c/Users/.../.ignition/...` to
find it, so a Windows-host install may still show the warning depending on your user folder.

## Still stuck?

Paste the contents of `preflight-report.txt` into the Discord `#preflight-help` channel. The TA monitors it daily and will respond within 24 hours on weekdays.
