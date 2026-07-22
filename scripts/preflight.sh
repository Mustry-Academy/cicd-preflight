#!/usr/bin/env bash
# Mustry Academy — CI/CD for Ignition Masterclass
# Preflight environment check
#
# Validates that the participant's machine has everything needed for Day 1.
# Writes a report to ./preflight-report.txt that the TA can read.
#
# The script is deliberately linear: read it top to bottom and each check is a
# self-contained block. If you add/remove/retier a check, update the "What it
# checks" table in README.md to match (it's hand-maintained on purpose).

set -u

FAILED=0
WARNINGS=0
REPORT_FILE="$(pwd)/preflight-report.txt"

# Flags (see --help). Set by the argument parser further down.
QUIET=0
NO_PULL=0
SKIP_SMOKE=0

# Colours (only when stdout is a terminal)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

# ---------------------------------------------------------------------------
# Logging helpers — each prints to the terminal (with colour) and appends a
# plain-text line to the report file.
# ---------------------------------------------------------------------------
# say — print to the terminal unless --quiet. The report file always gets the
# full record regardless; --quiet only trims the on-screen noise (passes/info),
# leaving warnings, failures and the final summary visible.
say() {
  [ "$QUIET" -eq 1 ] || echo "$1"
}

log_pass() {
  say "${GREEN}✓${RESET} $1"
  echo "PASS: $1" >> "$REPORT_FILE"
}

log_fail() {
  echo "${RED}✗${RESET} $1"
  echo "  ${YELLOW}→ $2${RESET}"
  echo "FAIL: $1" >> "$REPORT_FILE"
  echo "  suggestion: $2" >> "$REPORT_FILE"
  FAILED=$((FAILED + 1))
}

log_warn() {
  echo "${YELLOW}!${RESET} $1"
  echo "  ${YELLOW}→ $2${RESET}"
  echo "WARN: $1" >> "$REPORT_FILE"
  echo "  note: $2" >> "$REPORT_FILE"
  WARNINGS=$((WARNINGS + 1))
}

log_info() {
  say "${BLUE}ℹ${RESET} $1"
  echo "INFO: $1" >> "$REPORT_FILE"
}

section() {
  say ""
  say "${BOLD}$1${RESET}"
  {
    echo ""
    echo "[$1]"
  } >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Severity taxonomy
# ---------------------------------------------------------------------------
# Every check is one of two tiers, and the tier decides what happens when its
# core requirement is absent or broken:
#
#   required     You cannot complete Day 1 without it. A miss is a hard FAILURE
#                and the script exits non-zero, so CI and the TA can gate on it.
#                  → OS, git, docker, gh, ignition image, gateway smoke test
#
#   recommended  Things work without it, but the labs are rougher. A miss is a
#                WARNING only and never changes the exit code.
#                  → VS Code, Designer Launcher, disk, RAM
#
# Soft sub-conditions can still downgrade: Docker is *required*, but "Docker is
# installed yet below the recommended version" is only a warning, because an old
# Docker still works. Use log_missing for the primary present/absent decision;
# fall back to log_warn directly for those soft sub-conditions.
REQUIRED="required"
RECOMMENDED="recommended"

# log_missing SEVERITY MESSAGE SUGGESTION
# Report an absent/broken requirement at the severity its tier dictates:
# a required miss fails, a recommended miss warns.
log_missing() {
  if [ "$1" = "$REQUIRED" ]; then
    log_fail "$2" "$3"
  else
    log_warn "$2" "$3"
  fi
}

# Compare semantic versions: returns 0 if $1 >= $2
version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# True when running inside WSL2 (the Designer Launcher, RAM and disk all care).
is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

# ---------------------------------------------------------------------------
# Docker / smoke-test helpers (shared by the image + smoke checks)
# ---------------------------------------------------------------------------
IGNITION_IMAGE="inductiveautomation/ignition:8.3.6"
SMOKE_CONTAINER="mustry-preflight-gateway"

# docker_ready — Docker is installed AND its daemon answers.
docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# smoke_cleanup — remove the throwaway gateway container. `docker run --rm` only
# cleans up on the container's own exit, so if the user Ctrl-Cs during the wait
# the container would linger. A trap (armed below) calls this on EXIT/INT/TERM.
# Safe to run repeatedly and when no container exists.
smoke_cleanup() {
  docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
}

# smoke_capture_logs — append the container's recent log lines to the report.
# Must run before smoke_cleanup on failure paths: once the container is gone,
# telling the user to run `docker logs` themselves can't work.
smoke_capture_logs() {
  {
    echo "  --- last log lines from $SMOKE_CONTAINER ---"
    docker logs --tail 20 "$SMOKE_CONTAINER" 2>&1 | sed 's/^/  /'
    echo "  --- end of logs ---"
  } >> "$REPORT_FILE" 2>/dev/null || true
}

# mark_launcher_found DIR — used by the Designer check. A designerlauncher* file
# inside DIR means the launcher has actually been configured ("strong"); a bare
# dir is a weaker hint ("weak"). Updates the DESIGNER_* globals.
mark_launcher_found() {
  [ -d "$1" ] || return 0
  if ls "$1"/designerlauncher* >/dev/null 2>&1; then
    DESIGNER_FOUND="strong"; DESIGNER_WHERE="$1"
  else
    DESIGNER_FOUND="${DESIGNER_FOUND:-weak}"; DESIGNER_WHERE="${DESIGNER_WHERE:-$1}"
  fi
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Mustry Academy preflight — checks your machine is ready for Day 1.

Usage: scripts/preflight.sh [options]

Options:
  --no-pull       Skip pulling the Ignition image (use a locally cached one)
  --skip-smoke    Skip starting the throwaway gateway container
  --quiet         Only print warnings, failures and the summary
  -h, --help      Show this help and exit

Exit status is non-zero if any *required* check fails.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --no-pull)    NO_PULL=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --quiet)      QUIET=1 ;;
    *)            echo "preflight: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Set up the report file and print the banner.
# ---------------------------------------------------------------------------
# Prefer the working directory for the report, but fall back to a temp dir if
# it's read-only (e.g. the repo was cloned somewhere the user can't write to).
if ! : > "$REPORT_FILE" 2>/dev/null; then
  REPORT_FILE="${TMPDIR:-/tmp}/preflight-report.txt"
fi

{
  echo "Mustry Academy — Preflight Report"
  echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "Host: $(uname -a)"
  echo "----------------------------------------"
} > "$REPORT_FILE"

say "${BOLD}Mustry Academy — Preflight${RESET}"
say "Checking that your machine is ready for Day 1..."
say ""

# ===========================================================================
# Checks run top to bottom. Keep README.md's "What it checks" table in sync.
# ===========================================================================

# --- Operating system (required) -------------------------------------------
section "Operating system"
OS="$(uname -s)"
case "$OS" in
  Linux)
    if is_wsl; then
      log_pass "Running on WSL2 ($(lsb_release -ds 2>/dev/null || grep ^PRETTY_NAME /etc/os-release | cut -d= -f2))"
    else
      log_pass "Running on Linux ($(lsb_release -ds 2>/dev/null || grep ^PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo unknown))"
    fi
    ;;
  Darwin)
    log_pass "Running on macOS $(sw_vers -productVersion 2>/dev/null)"
    if [ "$(uname -m)" = "arm64" ]; then
      log_info "Apple Silicon detected — Ignition publishes linux/arm64 images, all good"
    fi
    ;;
  *)
    log_missing "$REQUIRED" "Unsupported OS: $OS" "Please run from inside WSL2 (Windows) or use macOS/Linux"
    ;;
esac

# --- Where you are working (required on WSL) -------------------------------
# The single biggest source of lost time in the labs. On WSL, a repo under
# /mnt/c (a DrvFs mount of the Windows disk) is governed by Windows ACLs, not
# by your WSL user. Your Windows user, your WSL user and the gateway
# container's user are three different identities there, so chown/chmod do not
# stick, Docker bind mounts lose permission bits, and the only thing that
# appears to work is running WSL as a Windows administrator. That hides the
# problem and makes each later lab worse. The lab setup scripts refuse to run
# from these paths, so catch it here — days before Day 1, not during Lab 02.
if is_wsl; then
  section "Working directory"
  FS_TYPE="$(stat -f -c %T . 2>/dev/null || echo unknown)"
  case "$FS_TYPE:$PWD" in
    drvfs:*|9p:*|v9fs:*|cifs:*|*:/mnt/[a-z]/*)
      log_fail "You are working on the Windows filesystem ($PWD)" \
        "Move your repos to your Linux home and re-run: mkdir -p ~/mustry-academy && cd ~/mustry-academy, then clone again there. Windows-drive paths break file ownership in ways chown cannot fix."
      ;;
    *)
      log_pass "Working on the Linux filesystem ($PWD)"
      ;;
  esac
fi

# --- Not running as root (required) ----------------------------------------
# Running the labs with sudo makes every file it creates root-owned, which is
# what causes the permission errors sudo appears to solve. The lab scripts
# refuse to run under sudo; teach the habit here.
if [ "$(id -u)" = "0" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    log_fail "This script is running under sudo" \
      "Run it as yourself: ./scripts/preflight.sh — the labs never need sudo, and running as root leaves root-owned files behind that break later steps."
  else
    log_warn "Running as the root user" \
      "Use a normal user account for the labs. Files created as root cause permission errors you would then need sudo to work around."
  fi
else
  log_pass "Running as a normal user (not root)"
fi

# --- Git (required) --------------------------------------------------------
section "Git"
if command -v git >/dev/null 2>&1; then
  GIT_VERSION="$(git --version | awk '{print $3}')"
  if version_ge "$GIT_VERSION" "2.40"; then
    log_pass "git $GIT_VERSION"
  else
    log_warn "git $GIT_VERSION (recommend ≥ 2.40)" "Consider upgrading; older versions work but some commands behave differently"
  fi
else
  log_missing "$REQUIRED" "git not found" "Install Git from https://git-scm.com/"
fi

# --- Docker (required) -----------------------------------------------------
section "Docker"
if command -v docker >/dev/null 2>&1; then
  DOCKER_VERSION="$(docker --version | awk '{print $3}' | tr -d ',')"
  if version_ge "$DOCKER_VERSION" "24.0"; then
    log_pass "docker $DOCKER_VERSION"
  else
    log_warn "docker $DOCKER_VERSION (recommend ≥ 24)" "Upgrade Docker Desktop or Docker Engine"
  fi

  if docker info >/dev/null 2>&1; then
    log_pass "Docker daemon is running"
  else
    log_missing "$REQUIRED" "Docker daemon is not running" "Start Docker Desktop (Win/Mac) or run 'sudo systemctl start docker' (Linux)"
  fi

  # Docker Compose v2 (the 'docker compose' subcommand, not the legacy 'docker-compose' binary)
  if docker compose version >/dev/null 2>&1; then
    log_pass "docker compose v$(docker compose version --short 2>/dev/null)"
  else
    log_missing "$REQUIRED" "docker compose v2 not found" "On Linux: 'sudo apt install docker-compose-plugin'. On Win/Mac it ships with Docker Desktop."
  fi
else
  log_missing "$REQUIRED" "docker not found" "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
fi

# --- GitHub CLI (required) -------------------------------------------------
section "GitHub CLI"
if command -v gh >/dev/null 2>&1; then
  log_pass "gh $(gh --version | head -1 | awk '{print $3}')"
  if gh auth status >/dev/null 2>&1; then
    log_pass "Authenticated to GitHub as $(gh api user --jq .login 2>/dev/null || echo unknown)"
  else
    log_missing "$REQUIRED" "gh is not authenticated" "Run 'gh auth login' and follow the prompts"
  fi
else
  log_missing "$REQUIRED" "gh (GitHub CLI) not found" "Install from https://cli.github.com/"
fi

# --- VS Code (recommended) -------------------------------------------------
section "VS Code"
if command -v code >/dev/null 2>&1; then
  log_pass "VS Code $(code --version 2>/dev/null | head -1)"
else
  log_missing "$RECOMMENDED" "'code' command not found in PATH" "Open VS Code → Cmd/Ctrl+Shift+P → 'Shell Command: Install code command in PATH'"
fi

# --- Ignition Designer Launcher (recommended) ------------------------------
# The Designer itself isn't a standalone install — it's downloaded on demand by
# the Designer Launcher, which is not on PATH and exposes no version CLI. So we
# look for the config dir it creates (~/.ignition/clientlauncher-data) plus the
# known per-OS install locations. Best-effort: a miss is a warning, and on WSL2
# we also probe the Windows host under /mnt/c.
section "Ignition Designer Launcher"
DESIGNER_FOUND=""   # "strong" | "weak" | ""
DESIGNER_WHERE=""

# 1. Primary signal: the launcher config dir (native home, plus Windows host on WSL2)
mark_launcher_found "$HOME/.ignition/clientlauncher-data"
if is_wsl; then
  for d in /mnt/c/Users/*/.ignition/clientlauncher-data \
           /mnt/c/Users/*/AppData/Roaming/Inductive\ Automation/clientlauncher-data; do
    mark_launcher_found "$d"
  done
fi

# 2. Per-OS native app locations (higher confidence where a fixed path exists)
case "$OS" in
  Darwin)
    for app in "/Applications/Designer Launcher.app" "$HOME/Applications/Designer Launcher.app"; do
      [ -d "$app" ] && { DESIGNER_FOUND="strong"; DESIGNER_WHERE="$app"; }
    done
    ;;
  Linux)
    # Native Linux has no fixed install path (tar.gz extracted anywhere) — a desktop
    # entry is the best app-level hint we have.
    [ -e "$HOME/.local/share/applications/designerlauncher.desktop" ] && \
      { DESIGNER_FOUND="strong"; DESIGNER_WHERE="$HOME/.local/share/applications/designerlauncher.desktop"; }
    if is_wsl; then
      for p in /mnt/c/Users/*/AppData/Local/Programs/Designer\ Launcher \
               /mnt/c/Program\ Files/*Designer*Launcher* \
               /mnt/c/Program\ Files\ \(x86\)/*Designer*Launcher*; do
        [ -e "$p" ] && { DESIGNER_FOUND="strong"; DESIGNER_WHERE="$p"; }
      done
    fi
    ;;
esac

if [ "$DESIGNER_FOUND" = "strong" ]; then
  log_pass "Ignition Designer Launcher detected ($DESIGNER_WHERE)"
elif [ "$DESIGNER_FOUND" = "weak" ]; then
  log_info "Found $DESIGNER_WHERE but no designerlauncher config yet — launch a Designer once to confirm"
else
  log_missing "$RECOMMENDED" "Ignition Designer Launcher not detected" \
    "Open your gateway web page → Downloads → Designer Launcher (or it installs on first Designer launch). Detection is best-effort — ignore this if you already have it."
fi

# --- Disk space (recommended) ----------------------------------------------
section "Disk space"
FREE_GB=""
if command -v df >/dev/null 2>&1; then
  case "$OS" in
    Linux)
      # GNU df: -B1G gives output in 1-GB blocks
      FREE_GB="$(df -B1G --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
      ;;
    Darwin)
      # BSD df wraps long filesystem names onto a second line, which makes
      # `awk NR==2` unreliable. -P forces single-line POSIX output; -k gives
      # 1024-byte blocks (most portable), and we convert to GB ourselves.
      FREE_KB="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')"
      [ -n "${FREE_KB:-}" ] && FREE_GB=$((FREE_KB / 1024 / 1024))
      ;;
  esac
fi

if [ -n "$FREE_GB" ] && [ "$FREE_GB" -ge 20 ] 2>/dev/null; then
  log_pass "Free disk space: ${FREE_GB} GB"
elif [ -n "$FREE_GB" ]; then
  log_missing "$RECOMMENDED" "Free disk space looks low (${FREE_GB} GB)" "Recommend ≥ 20 GB free for Ignition images + Docker volumes"
else
  log_missing "$RECOMMENDED" "Could not determine free disk space" "Run 'df -h .' manually and confirm you have ≥ 20 GB free"
fi

# On WSL2 this measures the Linux/WSL2 filesystem, NOT the Windows C: drive.
# That's the number that matters (Docker images and volumes live here), but it
# can differ a lot from what Windows Explorer shows — so call it out explicitly.
if is_wsl; then
  log_info "Disk space above is measured on the WSL2 filesystem, not your Windows C: drive — Docker stores images/volumes here, so this is the figure that counts"
fi

# --- Memory (recommended) --------------------------------------------------
# Total physical RAM. Ignition + Docker want ~8 GB to run comfortably. We check
# total (stable) rather than 'free' (too volatile to threshold reliably).
section "Memory"
TOTAL_RAM_GB=""
case "$OS" in
  Linux)
    # MemTotal in /proc/meminfo is in kB. On WSL2 this reflects the memory the
    # WSL2 VM is allowed — i.e. the memory actually available to Docker.
    if [ -r /proc/meminfo ]; then
      MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
      [ -n "${MEM_KB:-}" ] && TOTAL_RAM_GB=$((MEM_KB / 1024 / 1024))
    fi
    ;;
  Darwin)
    # hw.memsize is total physical RAM in bytes.
    MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null)"
    [ -n "${MEM_BYTES:-}" ] && TOTAL_RAM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
    ;;
esac

if [ -n "$TOTAL_RAM_GB" ] && [ "$TOTAL_RAM_GB" -ge 8 ] 2>/dev/null; then
  log_pass "Total RAM: ${TOTAL_RAM_GB} GB"
elif [ -n "$TOTAL_RAM_GB" ]; then
  log_missing "$RECOMMENDED" "Total RAM looks low (${TOTAL_RAM_GB} GB)" "Recommend ≥ 8 GB; Ignition + Docker can be tight below that. On WSL2, raise the limit via a .wslconfig 'memory=' setting."
else
  log_missing "$RECOMMENDED" "Could not determine total RAM" "Confirm you have ≥ 8 GB available to Docker"
fi

if is_wsl; then
  log_info "RAM above is the WSL2 VM allocation (set in C:\\Users\\<you>\\.wslconfig), not your full Windows RAM"
fi

# --- Ignition image (required) ---------------------------------------------
section "Ignition image"
if [ "$NO_PULL" -eq 1 ]; then
  log_info "Skipping image pull (--no-pull) — relying on a locally cached image"
elif ! docker_ready; then
  log_warn "Skipping image pull (Docker not available)" "Fix Docker first, then re-run"
else
  say "  Pulling $IGNITION_IMAGE (this may take a few minutes on first run)..."
  if docker pull "$IGNITION_IMAGE" >/dev/null 2>&1; then
    log_pass "Pulled $IGNITION_IMAGE"
  else
    log_missing "$REQUIRED" "Could not pull $IGNITION_IMAGE" "Check internet connectivity and Docker Hub access; corporate firewalls sometimes block this"
  fi
fi

# --- Gateway smoke test (required) -----------------------------------------
section "Gateway smoke test"
if [ "$SKIP_SMOKE" -eq 1 ]; then
  log_info "Skipping gateway smoke test (--skip-smoke)"
elif ! docker_ready; then
  log_warn "Skipping gateway smoke test (Docker not available)" "Fix Docker first, then re-run"
else
  # Clean up any previous run, and make sure an interrupt mid-wait tears the
  # container down too (--rm alone only fires on the container's own exit).
  smoke_cleanup
  trap 'smoke_cleanup' EXIT
  trap 'smoke_cleanup; exit 130' INT TERM

  # Publish the gateway's 8088 to a Docker-assigned ephemeral host port, so a
  # busy host port can't fail the test. We then ask Docker which port it picked.
  say "  Starting a temporary Ignition gateway on a free port..."
  if docker run -d --rm \
       --name "$SMOKE_CONTAINER" \
       -p 8088 \
       -e ACCEPT_IGNITION_EULA=Y \
       -e GATEWAY_ADMIN_PASSWORD=preflight \
       "$IGNITION_IMAGE" >/dev/null 2>&1; then
    # docker port -> e.g. "0.0.0.0:54321"; take the trailing port number.
    # On Docker Desktop the dynamically assigned mapping can take a moment to
    # become visible after `docker run -d` returns, so poll instead of reading
    # it once — a single immediate read intermittently comes back empty.
    SMOKE_HOST_PORT=""
    for i in $(seq 1 10); do
      SMOKE_HOST_PORT="$(docker port "$SMOKE_CONTAINER" 8088/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
      [ -n "$SMOKE_HOST_PORT" ] && break
      sleep 1
    done
    if [ -z "$SMOKE_HOST_PORT" ]; then
      log_missing "$REQUIRED" "Could not determine the gateway's published port (waited 10s)" "The container's last log lines are in $REPORT_FILE — paste the report into Discord #preflight-help"
      smoke_capture_logs
      smoke_cleanup
    else
      # Wait up to 90s for the gateway to come up
      SMOKE_OK=0
      for i in $(seq 1 30); do
        if curl -fsS -o /dev/null --max-time 3 "http://localhost:${SMOKE_HOST_PORT}/system/gwinfo" 2>/dev/null; then
          SMOKE_OK=1
          break
        fi
        sleep 3
      done

      if [ "$SMOKE_OK" -eq 1 ]; then
        # Each 3s sleep runs only after a failed probe, so on success at
        # iteration i exactly (i-1) sleeps have elapsed — not i.
        log_pass "Gateway responded on http://localhost:${SMOKE_HOST_PORT} (took ~$(((i - 1) * 3))s to start)"
      else
        log_missing "$REQUIRED" "Gateway did not respond within 90s" "The container's last log lines are in $REPORT_FILE — paste the report into Discord #preflight-help"
        smoke_capture_logs
      fi
      smoke_cleanup
    fi
  else
    log_missing "$REQUIRED" "Could not start a gateway container" "Ensure Docker has enough memory; any container logs were appended to $REPORT_FILE"
    smoke_capture_logs
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "${BOLD}Summary${RESET}"
echo "Report written to: $REPORT_FILE"
echo ""

{
  echo ""
  echo "----------------------------------------"
  echo "Summary: $FAILED failures, $WARNINGS warnings"
} >> "$REPORT_FILE"

if [ "$FAILED" -eq 0 ]; then
  echo "${GREEN}${BOLD}All required checks passed.${RESET}"
  if [ "$WARNINGS" -gt 0 ]; then
    echo "${YELLOW}${WARNINGS} warning(s) — review above.${RESET}"
  fi
  echo ""
  echo "Paste the report into Discord #preflight-help to let the TA know you're ready."
  exit 0
else
  echo "${RED}${BOLD}${FAILED} required check(s) failed.${RESET}"
  echo "Read the suggestions above, then paste $REPORT_FILE into Discord #preflight-help."
  exit 1
fi
