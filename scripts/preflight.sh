#!/usr/bin/env bash
# Mustry Academy — CI/CD for Ignition Masterclass
# Preflight environment check
#
# Validates that the participant's machine has everything needed for Day 1.
# Writes a report to ./preflight-report.txt that the TA can read.

set -u

REPORT_FILE="$(pwd)/preflight-report.txt"
FAILED=0
WARNINGS=0

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

# Initialise the report file
{
  echo "Mustry Academy — Preflight Report"
  echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "Host: $(uname -a)"
  echo "----------------------------------------"
} > "$REPORT_FILE"

log_pass() {
  echo "${GREEN}✓${RESET} $1"
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
  echo "${BLUE}ℹ${RESET} $1"
  echo "INFO: $1" >> "$REPORT_FILE"
}

section() {
  echo ""
  echo "${BOLD}$1${RESET}"
  echo "" >> "$REPORT_FILE"
  echo "[$1]" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Severity taxonomy
# ---------------------------------------------------------------------------
# Every check belongs to exactly one tier, and that tier decides what happens
# when its core requirement is absent or broken:
#
#   required     You literally cannot complete Day 1 without it. A miss is a
#                hard FAILURE and the script exits non-zero, so CI and the TA
#                can gate on it.   (os, git, docker, gh, ignition image, smoke)
#
#   recommended  Things work without it, but the labs are rougher. A miss is a
#                WARNING only and never changes the exit code.
#                                  (VS Code, Designer Launcher, disk, RAM)
#
# Soft sub-conditions can still downgrade: Docker is *required*, but "Docker is
# installed yet below the recommended version" is only a warning, because an
# old Docker still works. Use log_missing for the primary present/absent
# decision; fall back to log_warn directly for those soft sub-conditions.
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

echo "${BOLD}Mustry Academy — Preflight${RESET}"
echo "Checking that your machine is ready for Day 1..."
echo ""

# ---------------------------------------------------------------------------
section "Operating system"
# ---------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      log_pass "Running on WSL2 ($(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep ^PRETTY_NAME | cut -d= -f2))"
    else
      log_pass "Running on Linux ($(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep ^PRETTY_NAME | cut -d= -f2 || echo unknown))"
    fi
    ;;
  Darwin)
    log_pass "Running on macOS $(sw_vers -productVersion 2>/dev/null)"
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ]; then
      log_info "Apple Silicon detected — Ignition publishes linux/arm64 images, all good"
    fi
    ;;
  *)
    log_missing "$REQUIRED" "Unsupported OS: $OS" "Please run from inside WSL2 (Windows) or use macOS/Linux"
    ;;
esac

# ---------------------------------------------------------------------------
section "Git"
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
section "Docker"
# ---------------------------------------------------------------------------
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
    COMPOSE_VERSION="$(docker compose version --short 2>/dev/null)"
    log_pass "docker compose v$COMPOSE_VERSION"
  else
    log_missing "$REQUIRED" "docker compose v2 not found" "On Linux: 'sudo apt install docker-compose-plugin'. On Win/Mac it ships with Docker Desktop."
  fi
else
  log_missing "$REQUIRED" "docker not found" "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
fi

# ---------------------------------------------------------------------------
section "GitHub CLI"
# ---------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  GH_VERSION="$(gh --version | head -1 | awk '{print $3}')"
  log_pass "gh $GH_VERSION"

  if gh auth status >/dev/null 2>&1; then
    GH_USER="$(gh api user --jq .login 2>/dev/null || echo unknown)"
    log_pass "Authenticated to GitHub as $GH_USER"
  else
    log_missing "$REQUIRED" "gh is not authenticated" "Run 'gh auth login' and follow the prompts"
  fi
else
  log_missing "$REQUIRED" "gh (GitHub CLI) not found" "Install from https://cli.github.com/"
fi

# ---------------------------------------------------------------------------
section "VS Code"
# ---------------------------------------------------------------------------
if command -v code >/dev/null 2>&1; then
  CODE_VERSION="$(code --version 2>/dev/null | head -1)"
  log_pass "VS Code $CODE_VERSION"
else
  log_missing "$RECOMMENDED" "'code' command not found in PATH" "Open VS Code → Cmd/Ctrl+Shift+P → 'Shell Command: Install code command in PATH'"
fi

# ---------------------------------------------------------------------------
section "Ignition Designer Launcher"
# ---------------------------------------------------------------------------
# The Designer itself isn't a standalone install — it's downloaded on demand by
# the Designer Launcher, which is not on PATH and exposes no version CLI. So we
# look for the config dir it creates (~/.ignition/clientlauncher-data) plus the
# known per-OS install locations. This is best-effort: a miss is a warning, not
# a failure, and on WSL2 we also probe the Windows host under /mnt/c.

DESIGNER_FOUND=""   # "strong" | "weak" | ""
DESIGNER_WHERE=""
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

check_launcher_dir() {   # $1 = a candidate clientlauncher-data dir
  [ -d "$1" ] || return 1
  if ls "$1"/designerlauncher* >/dev/null 2>&1; then
    DESIGNER_FOUND="strong"; DESIGNER_WHERE="$1"
  else
    DESIGNER_FOUND="${DESIGNER_FOUND:-weak}"; DESIGNER_WHERE="${DESIGNER_WHERE:-$1}"
  fi
}

# 1. Primary signal: the launcher config dir (native home, plus Windows host on WSL2)
check_launcher_dir "$HOME/.ignition/clientlauncher-data"
if [ "$IS_WSL" -eq 1 ]; then
  for d in /mnt/c/Users/*/.ignition/clientlauncher-data \
           /mnt/c/Users/*/AppData/Roaming/Inductive\ Automation/clientlauncher-data; do
    check_launcher_dir "$d"
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
    if [ "$IS_WSL" -eq 1 ]; then
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

# ---------------------------------------------------------------------------
section "Disk and memory"
# ---------------------------------------------------------------------------
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
      if [ -n "${FREE_KB:-}" ]; then
        FREE_GB=$((FREE_KB / 1024 / 1024))
      fi
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
if grep -qi microsoft /proc/version 2>/dev/null; then
  log_info "Disk space above is measured on the WSL2 filesystem, not your Windows C: drive — Docker stores images/volumes here, so this is the figure that counts"
fi

# Total physical RAM. Ignition + Docker want ~8 GB to run comfortably. We check
# total (stable) rather than 'free' (too volatile to threshold reliably).
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

if grep -qi microsoft /proc/version 2>/dev/null; then
  log_info "RAM above is the WSL2 VM allocation (set in C:\\Users\\<you>\\.wslconfig), not your full Windows RAM"
fi

# ---------------------------------------------------------------------------
section "Ignition image"
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "  Pulling inductiveautomation/ignition:8.3 (this may take a few minutes on first run)..."
  if docker pull inductiveautomation/ignition:8.3 >/dev/null 2>&1; then
    log_pass "Pulled inductiveautomation/ignition:8.3"
  else
    log_missing "$REQUIRED" "Could not pull inductiveautomation/ignition:8.3" "Check internet connectivity and Docker Hub access; corporate firewalls sometimes block this"
  fi
else
  log_warn "Skipping image pull (Docker not available)" "Fix Docker first, then re-run"
fi

# ---------------------------------------------------------------------------
section "Gateway smoke test"
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_NAME="mustry-preflight-gateway"
  # Clean up any previous run
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  echo "  Starting a temporary Ignition gateway on port 18088..."
  if docker run -d --rm \
       --name "$CONTAINER_NAME" \
       -p 18088:8088 \
       -e ACCEPT_IGNITION_EULA=Y \
       -e GATEWAY_ADMIN_PASSWORD=preflight \
       inductiveautomation/ignition:8.3 >/dev/null 2>&1; then
    # Wait up to 90s for the gateway to come up
    SUCCESS=0
    for i in $(seq 1 30); do
      if curl -fsS -o /dev/null --max-time 3 http://localhost:18088/system/gwinfo 2>/dev/null; then
        SUCCESS=1
        break
      fi
      sleep 3
    done

    if [ $SUCCESS -eq 1 ]; then
      log_pass "Gateway responded on http://localhost:18088 (took ~$((i * 3))s to start)"
    else
      log_missing "$REQUIRED" "Gateway did not respond within 90s" "Run 'docker logs $CONTAINER_NAME' to see what went wrong, then check Discord #preflight-help"
    fi

    # Tear down
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    log_missing "$REQUIRED" "Could not start a gateway container" "Check that port 18088 is free and Docker has enough memory"
  fi
fi

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
