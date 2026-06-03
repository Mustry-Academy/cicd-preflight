# CI/CD Masterclass — Preflight

> Run this **at least 7 days before Day 1** to validate that your environment is ready.

The preflight script checks that you have all the tools required for the masterclass installed and working, and that you can successfully pull and run an Ignition 8.3 Docker image.

## Quick start

```bash
git clone https://github.com/mustry-academy/cicd-preflight.git
cd cicd-preflight
./scripts/preflight.sh
```

The script writes a report to `./preflight-report.txt`. **Paste the contents of that file into the Discord `#preflight-help` channel** so the TA can confirm you're ready or help debug.

## What it checks

| Check | Required |
|---|---|
| Operating system (and WSL2 on Windows) | ✅ |
| `git` ≥ 2.40 | ✅ |
| `docker` ≥ 24 | ✅ |
| `docker compose` v2 | ✅ |
| `gh` (GitHub CLI) and `gh auth status` | ✅ |
| VS Code installed | ✅ |
| Ignition Designer Launcher installed (best-effort detection) | Recommended |
| At least 8 GB RAM free for Docker | ✅ |
| Can pull `inductiveautomation/ignition:8.3` | ✅ |
| Can start a gateway container and hit `http://localhost:8088` | ✅ |

## If something fails

1. Read the suggestion the script prints
2. Check the [`troubleshooting.md`](./troubleshooting.md) guide
3. Post your `preflight-report.txt` in the Discord `#preflight-help` channel
4. The TA will follow up within 24h on weekdays

## Platform notes

- **Windows:** you must use **WSL2 with Docker Desktop's WSL2 backend**. Run the preflight script from inside Ubuntu (or your WSL distro of choice). Native Windows / Git Bash setups are not supported.
- **macOS:** Apple Silicon is fully supported. Ignition publishes `linux/arm64` images.
- **Linux:** Docker Engine + Docker Compose v2. The smoothest experience.

## Licence

Apache 2.0. See [`LICENSE`](./LICENSE).
