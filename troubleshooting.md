# Troubleshooting the preflight

## Windows: "docker not found" or it works in CMD but not WSL

You must run the preflight from inside WSL2, not from CMD or Git Bash. In Docker Desktop → Settings → Resources → WSL Integration, enable integration for your WSL distro (typically Ubuntu).

## "Docker daemon is not running"

- **Windows / macOS:** open Docker Desktop and wait for the whale icon to stop animating
- **Linux:** `sudo systemctl start docker` (and `sudo systemctl enable docker` for auto-start)
- **Linux, "permission denied":** add yourself to the `docker` group with `sudo usermod -aG docker $USER`, then log out and back in

## "Could not pull inductiveautomation/ignition:8.3"

This is usually a network issue. Try:

```bash
curl -I https://hub.docker.com
docker pull hello-world
```

If those fail too, you're behind a corporate proxy. Configure Docker Desktop's proxy settings in Settings → Resources → Proxies, or set `HTTPS_PROXY` in your shell. If only the Ignition pull fails, your firewall is filtering Docker Hub content — talk to your IT team.

## "Gateway did not respond within 90s"

Three common causes:

1. **Port 18088 already in use.** `lsof -i :18088` (Mac/Linux) or `netstat -ano | findstr 18088` (Windows) to find what's using it.
2. **Docker has too little memory.** In Docker Desktop → Settings → Resources, allocate at least 4 GB RAM to Docker.
3. **First-pull slowness.** Try `docker logs mustry-preflight-gateway` (if the container is still around) or just re-run the preflight; subsequent runs are much faster.

## "gh is not authenticated"

```bash
gh auth login
```

Choose GitHub.com → HTTPS → "Login with a web browser" → follow the prompts. The script will pop a one-time code; enter it in the browser.

## VS Code "code" command not found

This isn't strictly required, but it makes the labs easier. To add it:

- **Mac:** open VS Code → `Cmd+Shift+P` → "Shell Command: Install 'code' command in PATH"
- **Windows / Linux:** it's typically already on PATH after a default install. Restart your shell first.

## Still stuck?

Paste the contents of `preflight-report.txt` into the Discord `#preflight-help` channel. The TA monitors it daily and will respond within 24 hours on weekdays.
