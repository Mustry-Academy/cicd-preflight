# CI/CD Masterclass — Preflight

> Run this **at least 7 days before Day 1** to validate that your environment is ready.

The preflight script checks that you have all the tools required for the masterclass installed and working, and that you can successfully pull and run an Ignition 8.3 Docker image.

## Quick start

```bash
mkdir -p ~/mustry-academy && cd ~/mustry-academy     # Windows: this must be your LINUX home
git clone https://github.com/mustry-academy/cicd-preflight.git
cd cicd-preflight
./scripts/preflight.sh
```

> **Windows:** run this inside WSL, and keep every course repo in your Linux home
> (`~/…`), never on your Windows drive (`/mnt/c/…`). The script fails if you are on
> `/mnt/c` — see [Platform notes](#platform-notes) for why.

The script writes a report to `./preflight-report.txt`. **Paste the contents of that file into the Discord `#preflight-help` channel** so the TA can confirm you're ready or help debug.

### Options

```
--no-pull       Skip pulling the Ignition image (use a locally cached one)
--skip-smoke    Skip starting the throwaway gateway container
--quiet         Only print warnings, failures and the summary
-h, --help      Show this help and exit
```

The image pull and gateway smoke test are the slow steps; `--no-pull --skip-smoke` makes for a fast re-run while you're fixing the lighter checks. Run `./scripts/preflight.sh --help` to see this list anytime.

## What it checks

Every check is one of two tiers:

- **Required** — you cannot complete Day 1 without it. A miss is a hard failure and the script exits non-zero.
- **Recommended** — things work without it, but the labs are rougher. A miss is only a warning and never changes the exit code.

<!-- Keep this table in sync with the checks in scripts/preflight.sh (top to bottom). -->

| Check | Tier |
|---|---|
| Operating system (and WSL2 on Windows) | Required |
| Working directory is on the Linux filesystem, not `/mnt/c` (WSL only) | Required |
| Not running as root / under `sudo` | Required |
| `git` ≥ 2.40 | Required |
| `docker` ≥ 24, daemon running, and `docker compose` v2 | Required |
| `gh` (GitHub CLI) installed and authenticated | Required |
| VS Code installed (`code` on PATH) | Recommended |
| Ignition Designer Launcher installed (best-effort detection) | Recommended |
| At least 20 GB free disk space | Recommended |
| At least 8 GB total RAM | Recommended |
| Containers can reach GitHub over HTTPS (detects corporate TLS interception) | Required |
| Can pull `inductiveautomation/ignition:8.3.6` | Required |
| Gateway container starts and responds over HTTP | Required |

## If something fails

1. Read the suggestion the script prints
2. Check the [`troubleshooting.md`](./troubleshooting.md) guide
3. Post your `preflight-report.txt` in the Discord `#preflight-help` channel
4. The TA will follow up within 24h on weekdays

## Platform notes

- **Windows:** you must use **WSL2 with Docker Desktop's WSL2 backend**. Run the preflight script from inside Ubuntu (or your WSL distro of choice). Native Windows / Git Bash setups are not supported. **Keep all course repos in your Linux home (`~/…`), never under `/mnt/c/…`.** A repo on the Windows drive is governed by Windows ACLs rather than your WSL user, so your Windows user, your WSL user and the gateway container's user are three different identities: `chown` and `chmod` do not stick, Docker bind mounts lose permission bits, and the only thing that seems to help is running WSL as a Windows administrator — which hides the problem and makes every later lab worse. The lab setup scripts refuse to run from there, and none of them ever need `sudo`. Note that the **disk space and RAM figures are measured inside WSL2, not for your whole Windows machine** — that's deliberate, since Docker images, volumes and containers live in WSL2. The RAM number is the WSL2 VM's allocation (configurable in `C:\Users\<you>\.wslconfig`).
- **macOS:** Apple Silicon is fully supported. Ignition publishes `linux/arm64` images.
- **Linux:** Docker Engine + Docker Compose v2. The smoothest experience.

## Licence

Apache 2.0. See [`LICENSE`](./LICENSE).
