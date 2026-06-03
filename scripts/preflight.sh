#!/usr/bin/env bash
# Mustry Academy — CI/CD for Ignition Masterclass
# Preflight environment check
#
# Validates that the participant's machine has everything needed for Day 1.
# Writes a report to ./preflight-report.txt that the TA can read.
#
# What gets checked, and at what severity, is declared once in the CHECKS
# manifest below — that is the single source of truth. The README's "What it
# checks" table is generated from it via `preflight.sh --list`, and CI fails if
# the two ever drift (see .github/workflows/ci.yml).

# Checks run through dynamic dispatch ("check_$id"), which shellcheck can't trace,
# so it wrongly reports every check_* function as unreachable / never invoked.
# Silence that across shellcheck versions: SC2317 (≤0.10) and SC2329 (≥0.10).
# shellcheck disable=SC2317,SC2329

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

# True when running inside WSL2 (the Designer Launcher, RAM and disk all care).
is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

# ===========================================================================
# CHECKS manifest — THE SINGLE SOURCE OF TRUTH.
#
# Format:  id|severity|README title
#   id        dispatches to the check_<id> function below
#   severity  required | recommended (drives pass/fail vs warn, and the table)
#   title     the human-facing row text in the README's "What it checks" table
#
# To add a check: add a row here and a matching check_<id> function, then run
# scripts/update-readme.sh. Order here is the order checks run and appear.
# ===========================================================================
# Backticks in the titles are literal Markdown, so the rows are single-quoted.
# shellcheck disable=SC2016
CHECKS=(
  'os|required|Operating system (and WSL2 on Windows)'
  'git|required|`git` ≥ 2.40'
  'docker|required|`docker` ≥ 24, daemon running, and `docker compose` v2'
  'gh|required|`gh` (GitHub CLI) installed and authenticated'
  'vscode|recommended|VS Code installed (`code` on PATH)'
  'designer|recommended|Ignition Designer Launcher installed (best-effort detection)'
  'disk|recommended|At least 20 GB free disk space'
  'ram|recommended|At least 8 GB total RAM'
  'image|required|Can pull `inductiveautomation/ignition:8.3.6`'
  'smoke|required|Gateway container starts and responds over HTTP'
)

# Settings the smoke/image checks share.
IGNITION_IMAGE="inductiveautomation/ignition:8.3.6"
SMOKE_CONTAINER="mustry-preflight-gateway"

# docker_ready — Docker is installed AND its daemon answers. The image and smoke
# checks both depend on this, so it lives in one place.
docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# smoke_cleanup — remove the throwaway gateway container. `docker run --rm` only
# cleans up on the container's own exit, so if the user Ctrl-Cs during the 90s
# wait the container would linger. A trap (armed in check_smoke) calls this on
# EXIT/INT/TERM. Safe to run repeatedly and when no container exists.
smoke_cleanup() {
  docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Individual checks. Each receives its severity tier as $1 (from the manifest)
# and is responsible for printing its own section header.
# ---------------------------------------------------------------------------
check_os() {
  local sev="$1"
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
      log_missing "$sev" "Unsupported OS: $OS" "Please run from inside WSL2 (Windows) or use macOS/Linux"
      ;;
  esac
}

check_git() {
  local sev="$1"
  section "Git"
  if command -v git >/dev/null 2>&1; then
    local v; v="$(git --version | awk '{print $3}')"
    if version_ge "$v" "2.40"; then
      log_pass "git $v"
    else
      log_warn "git $v (recommend ≥ 2.40)" "Consider upgrading; older versions work but some commands behave differently"
    fi
  else
    log_missing "$sev" "git not found" "Install Git from https://git-scm.com/"
  fi
}

check_docker() {
  local sev="$1"
  section "Docker"
  if command -v docker >/dev/null 2>&1; then
    local v; v="$(docker --version | awk '{print $3}' | tr -d ',')"
    if version_ge "$v" "24.0"; then
      log_pass "docker $v"
    else
      log_warn "docker $v (recommend ≥ 24)" "Upgrade Docker Desktop or Docker Engine"
    fi

    if docker info >/dev/null 2>&1; then
      log_pass "Docker daemon is running"
    else
      log_missing "$sev" "Docker daemon is not running" "Start Docker Desktop (Win/Mac) or run 'sudo systemctl start docker' (Linux)"
    fi

    # Docker Compose v2 (the 'docker compose' subcommand, not the legacy 'docker-compose' binary)
    if docker compose version >/dev/null 2>&1; then
      log_pass "docker compose v$(docker compose version --short 2>/dev/null)"
    else
      log_missing "$sev" "docker compose v2 not found" "On Linux: 'sudo apt install docker-compose-plugin'. On Win/Mac it ships with Docker Desktop."
    fi
  else
    log_missing "$sev" "docker not found" "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
  fi
}

check_gh() {
  local sev="$1"
  section "GitHub CLI"
  if command -v gh >/dev/null 2>&1; then
    log_pass "gh $(gh --version | head -1 | awk '{print $3}')"
    if gh auth status >/dev/null 2>&1; then
      log_pass "Authenticated to GitHub as $(gh api user --jq .login 2>/dev/null || echo unknown)"
    else
      log_missing "$sev" "gh is not authenticated" "Run 'gh auth login' and follow the prompts"
    fi
  else
    log_missing "$sev" "gh (GitHub CLI) not found" "Install from https://cli.github.com/"
  fi
}

check_vscode() {
  local sev="$1"
  section "VS Code"
  if command -v code >/dev/null 2>&1; then
    log_pass "VS Code $(code --version 2>/dev/null | head -1)"
  else
    log_missing "$sev" "'code' command not found in PATH" "Open VS Code → Cmd/Ctrl+Shift+P → 'Shell Command: Install code command in PATH'"
  fi
}

# Mark the Designer Launcher as found in $1 (a clientlauncher-data dir). A
# designerlauncher* file inside means it has actually been configured ("strong");
# a bare dir is a weaker hint ("weak"). Updates the DESIGNER_* globals.
check_launcher_dir() {
  [ -d "$1" ] || return 0
  if ls "$1"/designerlauncher* >/dev/null 2>&1; then
    DESIGNER_FOUND="strong"; DESIGNER_WHERE="$1"
  else
    DESIGNER_FOUND="${DESIGNER_FOUND:-weak}"; DESIGNER_WHERE="${DESIGNER_WHERE:-$1}"
  fi
}

check_designer() {
  local sev="$1"
  section "Ignition Designer Launcher"
  # The Designer itself isn't a standalone install — it's downloaded on demand by
  # the Designer Launcher, which is not on PATH and exposes no version CLI. So we
  # look for the config dir it creates (~/.ignition/clientlauncher-data) plus the
  # known per-OS install locations. Best-effort: a miss is a warning, and on WSL2
  # we also probe the Windows host under /mnt/c.
  DESIGNER_FOUND=""   # "strong" | "weak" | ""
  DESIGNER_WHERE=""

  # 1. Primary signal: the launcher config dir (native home, plus Windows host on WSL2)
  check_launcher_dir "$HOME/.ignition/clientlauncher-data"
  if is_wsl; then
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
    log_missing "$sev" "Ignition Designer Launcher not detected" \
      "Open your gateway web page → Downloads → Designer Launcher (or it installs on first Designer launch). Detection is best-effort — ignore this if you already have it."
  fi
}

check_disk() {
  local sev="$1"
  section "Disk space"
  local free_gb=""
  if command -v df >/dev/null 2>&1; then
    case "$OS" in
      Linux)
        # GNU df: -B1G gives output in 1-GB blocks
        free_gb="$(df -B1G --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
        ;;
      Darwin)
        # BSD df wraps long filesystem names onto a second line, which makes
        # `awk NR==2` unreliable. -P forces single-line POSIX output; -k gives
        # 1024-byte blocks (most portable), and we convert to GB ourselves.
        local free_kb; free_kb="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')"
        [ -n "${free_kb:-}" ] && free_gb=$((free_kb / 1024 / 1024))
        ;;
    esac
  fi

  if [ -n "$free_gb" ] && [ "$free_gb" -ge 20 ] 2>/dev/null; then
    log_pass "Free disk space: ${free_gb} GB"
  elif [ -n "$free_gb" ]; then
    log_missing "$sev" "Free disk space looks low (${free_gb} GB)" "Recommend ≥ 20 GB free for Ignition images + Docker volumes"
  else
    log_missing "$sev" "Could not determine free disk space" "Run 'df -h .' manually and confirm you have ≥ 20 GB free"
  fi

  # On WSL2 this measures the Linux/WSL2 filesystem, NOT the Windows C: drive.
  # That's the number that matters (Docker images and volumes live here), but it
  # can differ a lot from what Windows Explorer shows — so call it out explicitly.
  if is_wsl; then
    log_info "Disk space above is measured on the WSL2 filesystem, not your Windows C: drive — Docker stores images/volumes here, so this is the figure that counts"
  fi
}

check_ram() {
  local sev="$1"
  section "Memory"
  # Total physical RAM. Ignition + Docker want ~8 GB to run comfortably. We check
  # total (stable) rather than 'free' (too volatile to threshold reliably).
  local total_gb=""
  case "$OS" in
    Linux)
      # MemTotal in /proc/meminfo is in kB. On WSL2 this reflects the memory the
      # WSL2 VM is allowed — i.e. the memory actually available to Docker.
      if [ -r /proc/meminfo ]; then
        local kb; kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
        [ -n "${kb:-}" ] && total_gb=$((kb / 1024 / 1024))
      fi
      ;;
    Darwin)
      # hw.memsize is total physical RAM in bytes.
      local bytes; bytes="$(sysctl -n hw.memsize 2>/dev/null)"
      [ -n "${bytes:-}" ] && total_gb=$((bytes / 1024 / 1024 / 1024))
      ;;
  esac

  if [ -n "$total_gb" ] && [ "$total_gb" -ge 8 ] 2>/dev/null; then
    log_pass "Total RAM: ${total_gb} GB"
  elif [ -n "$total_gb" ]; then
    log_missing "$sev" "Total RAM looks low (${total_gb} GB)" "Recommend ≥ 8 GB; Ignition + Docker can be tight below that. On WSL2, raise the limit via a .wslconfig 'memory=' setting."
  else
    log_missing "$sev" "Could not determine total RAM" "Confirm you have ≥ 8 GB available to Docker"
  fi

  if is_wsl; then
    log_info "RAM above is the WSL2 VM allocation (set in C:\\Users\\<you>\\.wslconfig), not your full Windows RAM"
  fi
}

check_image() {
  local sev="$1"
  section "Ignition image"
  if [ "$NO_PULL" -eq 1 ]; then
    log_info "Skipping image pull (--no-pull) — relying on a locally cached image"
    return
  fi
  if ! docker_ready; then
    log_warn "Skipping image pull (Docker not available)" "Fix Docker first, then re-run"
    return
  fi
  say "  Pulling $IGNITION_IMAGE (this may take a few minutes on first run)..."
  if docker pull "$IGNITION_IMAGE" >/dev/null 2>&1; then
    log_pass "Pulled $IGNITION_IMAGE"
  else
    log_missing "$sev" "Could not pull $IGNITION_IMAGE" "Check internet connectivity and Docker Hub access; corporate firewalls sometimes block this"
  fi
}

check_smoke() {
  local sev="$1"
  section "Gateway smoke test"
  if [ "$SKIP_SMOKE" -eq 1 ]; then
    log_info "Skipping gateway smoke test (--skip-smoke)"
    return
  fi
  if ! docker_ready; then
    log_warn "Skipping gateway smoke test (Docker not available)" "Fix Docker first, then re-run"
    return
  fi

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
    local port; port="$(docker port "$SMOKE_CONTAINER" 8088/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
    if [ -z "$port" ]; then
      log_missing "$sev" "Could not determine the gateway's published port" "Run 'docker port $SMOKE_CONTAINER' to inspect, then check Discord #preflight-help"
      docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
      return
    fi

    # Wait up to 90s for the gateway to come up
    local ok=0 i
    for i in $(seq 1 30); do
      if curl -fsS -o /dev/null --max-time 3 "http://localhost:${port}/system/gwinfo" 2>/dev/null; then
        ok=1
        break
      fi
      sleep 3
    done

    if [ "$ok" -eq 1 ]; then
      log_pass "Gateway responded on http://localhost:${port} (took ~$((i * 3))s to start)"
    else
      log_missing "$sev" "Gateway did not respond within 90s" "Run 'docker logs $SMOKE_CONTAINER' to see what went wrong, then check Discord #preflight-help"
    fi

    docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
  else
    log_missing "$sev" "Could not start a gateway container" "Ensure Docker has enough memory; see 'docker logs $SMOKE_CONTAINER' if it was created"
  fi
}

# print_checks_table — emit the README's "What it checks" table from the
# manifest. Used by scripts/update-readme.sh and the CI sync check.
print_checks_table() {
  echo "| Check | Tier |"
  echo "|---|---|"
  local entry sev title tier
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r _ sev title <<< "$entry"
    if [ "$sev" = "$REQUIRED" ]; then tier="Required"; else tier="Recommended"; fi
    echo "| $title | $tier |"
  done
}

# validate_manifest — fail fast on a malformed CHECKS row (typo'd severity or a
# missing check_<id> function) rather than silently skipping a check at runtime.
validate_manifest() {
  local entry id sev
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r id sev _ <<< "$entry"
    case "$sev" in
      "$REQUIRED"|"$RECOMMENDED") ;;
      *) echo "preflight: manifest error — check '$id' has unknown severity '$sev'" >&2; exit 2 ;;
    esac
    if ! declare -F "check_$id" >/dev/null; then
      echo "preflight: manifest error — no check_$id function for check '$id'" >&2
      exit 2
    fi
  done
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
  --list          Print the checks table (Markdown) and exit
  -h, --help      Show this help and exit

Exit status is non-zero if any *required* check fails.
EOF
}

validate_manifest

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --list)       print_checks_table; exit 0 ;;
    --no-pull)    NO_PULL=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --quiet)      QUIET=1 ;;
    *)            echo "preflight: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Run
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

OS="$(uname -s)"   # set early so checks ordered after check_os can still rely on it
for entry in "${CHECKS[@]}"; do
  IFS='|' read -r id sev _ <<< "$entry"
  "check_$id" "$sev"
done

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
