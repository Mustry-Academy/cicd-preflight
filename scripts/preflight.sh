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
#                  → OS, git (+identity), python, docker, gh (+scopes, push
#                    auth), container HTTPS, host ports, course images,
#                    gateway smoke test
#
#   recommended  Things work without it, but the labs are rougher. A miss is a
#                WARNING only and never changes the exit code.
#                  → VS Code, Designer Launcher, disk, RAM, Docker memory,
#                    Docker Hub login, local Ignition install
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

# ---------------------------------------------------------------------------
# Container HTTPS helpers (the "GitHub from inside a container" check)
# ---------------------------------------------------------------------------
# The labs run the GitHub Actions runner as a container (myoung34/github-runner),
# and that container verifies TLS with the image's own CA bundle — not the
# laptop's. Corporate laptops often sit behind a TLS-intercepting proxy
# (Zscaler, Netskope, GlobalProtect, ...) whose root CA is pushed to the OS
# store, so the browser, gh, git and even `docker pull` all work, while any
# HTTPS call made *inside* a container fails with "unable to get local issuer
# certificate". Nothing else in this script would catch that, so we probe from
# a throwaway curl container. The image is pinned for reproducibility.
CURL_IMAGE="curlimages/curl:8.14.1"
# Hosts the runner needs: registration + API, checkout, and the job long-poll.
GITHUB_HOSTS="api.github.com github.com pipelines.actions.githubusercontent.com"

# container_https_probe HOST — GET https://HOST/ from inside a container.
# Returns curl's own exit status; any HTTP response (even a 404) counts as
# success because we only care whether the TLS handshake and transport work.
# One retry absorbs a transient blip (seen in testing), while a certificate
# failure (60) is deterministic so it's returned straight away.
container_https_probe() {
  local rc
  for _ in 1 2; do
    docker run --rm "$CURL_IMAGE" -sS -o /dev/null --max-time 15 "https://$1/" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 60 ] && return "$rc"
  done
  return "$rc"
}

# Where troubleshooting.md tells students to keep their exported corporate root
# CA. If it exists and makes the probe succeed, the student has done the fix
# and the check passes (with a reminder about the compose override).
CORP_CA_FILE="$HOME/corp-root.crt"

# container_https_probe_with_ca HOST — same probe, but trusting CORP_CA_FILE
# instead of the image's bundle (behind an intercepting proxy every site is
# re-signed by that CA, so it's all curl needs to see).
container_https_probe_with_ca() {
  docker run --rm -v "$CORP_CA_FILE:/corp-root.crt:ro" "$CURL_IMAGE" \
    --cacert /corp-root.crt -sS -o /dev/null --max-time 15 "https://$1/" >/dev/null 2>&1
}

# corp_ca_has_root — true when CORP_CA_FILE contains at least one self-signed
# certificate. curl accepts a partial chain, so an exported *intermediate*
# would pass the probe above — but update-ca-certificates/OpenSSL in the
# runner need the root, so we'd be handing out a false green. Best-effort:
# without a host openssl we can't tell and let it through.
corp_ca_has_root() {
  command -v openssl >/dev/null 2>&1 || return 0
  local n i
  n="$(grep -c 'BEGIN CERTIFICATE' "$CORP_CA_FILE" 2>/dev/null || echo 0)"
  for i in $(seq 1 "$n"); do
    # Print subject and issuer without their labels; a duplicate line means
    # they're equal, i.e. self-signed. Works for OpenSSL and LibreSSL output.
    if awk -v k="$i" '/BEGIN CERTIFICATE/{c++} c==k' "$CORP_CA_FILE" \
         | openssl x509 -noout -subject -issuer 2>/dev/null \
         | sed 's/^[a-z]*= *//' | uniq -d | grep -q .; then
      return 0
    fi
  done
  return 1
}

# container_cert_issuer HOST — who signed the certificate a container sees for
# HOST. Only used for the report after a verification failure: -k skips the
# check so curl will still print the chain, and nothing is downloaded (-o
# /dev/null). "Sectigo"/"DigiCert" is GitHub's real CA; "Zscaler", "Netskope",
# "<Company> Root CA" etc. is a proxy re-signing the connection.
container_cert_issuer() {
  docker run --rm "$CURL_IMAGE" -kv -o /dev/null --max-time 15 "https://$1/" 2>&1 \
    | sed -n 's/^\* *issuer: *//p' | head -1
}

# ---------------------------------------------------------------------------
# Course inventory (what the labs actually publish and pull)
# ---------------------------------------------------------------------------
# Images every lab laptop needs. Pulled in full during the preflight so the
# multi-GB download happens a week early and not over classroom Wi-Fi — and
# because Docker Hub rate-limits anonymous pulls PER IP ADDRESS, a whole room
# behind one NAT pulling on Day 1 gets throttled. (Capstone server-side images
# such as caddy/postgres are deliberately not in this list.)
COURSE_IMAGES="$IGNITION_IMAGE timescale/timescaledb:latest-pg16 myoung34/github-runner:latest"

# Host ports the lab compose files publish (labs 02–07). 80/443 are only used
# by the capstone's server-side stack, so they are not checked here.
LAB_PORTS="8088 8089 8090 8060 8061 8062 5432"

# docker_hub_logged_in — Docker keeps a per-registry entry in config.json once
# `docker login` has succeeded, even when the secret itself lives in a
# credential helper (the entry is then just an empty object).
docker_hub_logged_in() {
  local cfg store
  cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  grep -q 'index.docker.io' "$cfg" 2>/dev/null && return 0
  # Signing in through Docker Desktop's own UI can leave config.json without
  # an auths entry; the credential helper it configures still knows.
  store="$(sed -n 's/.*"credsStore" *: *"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -1)"
  [ -n "$store" ] && command -v "docker-credential-$store" >/dev/null 2>&1 \
    && "docker-credential-$store" list 2>/dev/null | grep -q 'index.docker.io'
}

# ssh_github_ok — a working SSH key for GitHub. GitHub closes the session with
# exit 1 even on success, so we look at the greeting instead of the status.
ssh_github_ok() {
  command -v ssh >/dev/null 2>&1 || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      git@github.com 2>&1 | grep -q 'successfully authenticated'
}

# port_owner PORT — best-effort name of what holds PORT, for the report. A
# running container of the student's own is the most common answer (a lab
# stack left up), so ask Docker first; the host view only ever shows the
# Docker proxy for those. On WSL2 a Windows-side program is invisible from here.
port_owner() {
  local c
  c="$(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null | head -1)"
  if [ -n "$c" ]; then
    echo "container $c"
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}'
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
  fi
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
  --no-pull       Skip pulling the course images (use locally cached ones)
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

  # Lab 01 starts with a commit. Without an identity git refuses with a
  # message that confuses first-timers. Read from inside the repo so a
  # conditional include for ~/mustry-academy counts too. Name only in the
  # report — the email is nobody else's business.
  if [ -n "$(git config --get user.name 2>/dev/null)" ] && [ -n "$(git config --get user.email 2>/dev/null)" ]; then
    log_pass "Commit identity set ($(git config --get user.name))"
  else
    log_missing "$REQUIRED" "git has no commit identity (user.name / user.email)" "Run: git config --global user.name \"Your Name\" && git config --global user.email \"you@example.com\""
  fi
else
  log_missing "$REQUIRED" "git not found" "Install Git from https://git-scm.com/"
fi

# --- Python (required) -----------------------------------------------------
# Lab 02–07 scripts hard-exit without python3, and Lab 03 installs its linters
# (ign-lint needs ≥ 3.10) into a venv. Ubuntu/WSL ships python3 WITHOUT the
# venv module, so we actually create one rather than trusting `command -v`.
section "Python"
if command -v python3 >/dev/null 2>&1; then
  PY_VERSION="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo 0)"
  if version_ge "$PY_VERSION" "3.10"; then
    log_pass "python3 $PY_VERSION"
  else
    log_missing "$REQUIRED" "python3 $PY_VERSION is too old (Lab 03's ign-lint needs ≥ 3.10)" "Ubuntu 22.04+ ships a new enough Python; on macOS: brew install python"
  fi
  VENV_TMP="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/preflight-venv-$$")"
  if python3 -m venv "$VENV_TMP/venv" >/dev/null 2>&1 && [ -x "$VENV_TMP/venv/bin/pip" ]; then
    log_pass "python3 can create virtual environments (venv + pip)"
  else
    log_missing "$REQUIRED" "python3 cannot create a virtual environment with pip" "Ubuntu/WSL: sudo apt install python3-venv — Lab 03 installs its linters into a venv"
  fi
  rm -rf "$VENV_TMP"
else
  log_missing "$REQUIRED" "python3 not found" "Ubuntu/WSL: sudo apt install python3 python3-venv. macOS: brew install python"
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

    # Memory Docker can actually use. On Docker Desktop that's the VM's
    # allocation, not the laptop's RAM (a 16 GB Mac often gives Docker 4 GB);
    # on WSL2 it's the .wslconfig limit. Labs 04–06 run three 1 GB gateways +
    # TimescaleDB + the runner and need ≥ 8 GB here. Rounded to the nearest GB
    # because the kernel reserves a little below the configured figure.
    DOCKER_MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    DOCKER_MEM_GB=$(( (DOCKER_MEM_BYTES + 512 * 1024 * 1024) / 1024 / 1024 / 1024 ))
    if [ "$DOCKER_MEM_BYTES" -eq 0 ] 2>/dev/null; then
      log_info "Could not read how much memory Docker has — check Docker Desktop → Settings → Resources"
    elif [ "$DOCKER_MEM_GB" -ge 8 ]; then
      log_pass "Memory available to Docker: ${DOCKER_MEM_GB} GB"
    else
      log_missing "$RECOMMENDED" "Memory available to Docker: ${DOCKER_MEM_GB} GB (labs 04–06 need ≥ 8 GB)" "Docker Desktop → Settings → Resources → Memory. On WSL2: raise memory= in C:\\Users\\<you>\\.wslconfig, then 'wsl --shutdown'"
    fi

    if docker_hub_logged_in; then
      log_pass "Logged in to Docker Hub"
    else
      log_missing "$RECOMMENDED" "Not logged in to Docker Hub" "Anonymous pulls are rate-limited per IP address and the whole classroom shares one. Create a free account at hub.docker.com and run 'docker login'"
    fi
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

    # Token scopes. Lab 03 pushes .github/workflows/*.yml, which GitHub
    # refuses over HTTPS unless the token has `workflow` — older gh logins
    # don't. Fine-grained tokens don't report scopes; let those through.
    GH_SCOPES="$(gh api -i user 2>/dev/null | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | tr -d '\r')"
    if [ -z "$GH_SCOPES" ]; then
      log_info "Could not read the token's scopes (fine-grained token?) — make sure it can push code and workflow files to your forks"
    else
      GH_MISSING_SCOPES=""
      for sc in repo workflow; do
        echo "$GH_SCOPES" | grep -qw "$sc" || GH_MISSING_SCOPES="$GH_MISSING_SCOPES $sc"
      done
      if [ -z "$GH_MISSING_SCOPES" ]; then
        log_pass "Token scopes include repo and workflow"
      else
        log_missing "$REQUIRED" "gh token is missing scope(s):$GH_MISSING_SCOPES" "Run: gh auth refresh -h github.com -s repo,workflow — without 'workflow', pushing a GitHub Actions file is rejected"
      fi
    fi

    # gh being logged in doesn't mean `git push` is: git needs either gh as
    # its HTTPS credential helper or a working SSH key. GitHub no longer
    # accepts passwords, so a bare HTTPS setup fails at the first push.
    # `gh auth setup-git` registers its helper per host (credential
    # "https://github.com"), not as the global credential.helper, so look at
    # every credential.*helper key.
    GIT_CRED_HELPERS="$(git config --get-regexp '^credential\..*helper$' 2>/dev/null | awk '{ $1=""; sub(/^ /, ""); if ($0 != "") print }' | sort -u | tr '\n' ' ')"
    if echo "$GIT_CRED_HELPERS" | grep -q 'gh auth git-credential'; then
      log_pass "git authenticates to GitHub through gh (HTTPS)"
    elif ssh_github_ok; then
      log_pass "git authenticates to GitHub over SSH"
    elif ls "$HOME"/.ssh/id_* >/dev/null 2>&1; then
      # A key exists but didn't work non-interactively — usually a passphrase
      # with no agent (WSL doesn't start one). That still works at the prompt.
      log_warn "An SSH key exists but did not authenticate to GitHub non-interactively" "Passphrase without an agent? Test with 'ssh -T git@github.com'. If that fails, run 'gh auth login' → SSH, or 'gh auth setup-git' for HTTPS"
    elif [ -n "$GIT_CRED_HELPERS" ]; then
      log_warn "git uses credential helper '${GIT_CRED_HELPERS% }' and has no SSH key" "If 'git push' asks for a password, run 'gh auth setup-git' so git reuses gh's token"
    else
      log_missing "$REQUIRED" "git has no way to authenticate to GitHub (no credential helper, no SSH key)" "Run 'gh auth setup-git' — GitHub does not accept passwords for git push"
    fi
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

# A locally *installed* gateway is the opposite of helpful: its service grabs
# 8088 at boot, so the lab gateways can't bind. Detection is path-based; on
# WSL2 the Windows install is what matters.
LOCAL_IGNITION=""
for p in /usr/local/ignition /opt/ignition "/Applications/Ignition"* \
         "$HOME/ignition" "/mnt/c/Program Files/Inductive Automation/Ignition"; do
  # A gateway install has these; a folder that merely happens to be called
  # "ignition" does not.
  if [ -f "$p/data/ignition.conf" ] || [ -d "$p/lib/core/gateway" ]; then
    LOCAL_IGNITION="$p"; break
  fi
done
if [ -n "$LOCAL_IGNITION" ]; then
  log_missing "$RECOMMENDED" "A local Ignition gateway install was found ($LOCAL_IGNITION)" "Its service listens on 8088 and starts at boot, which blocks the lab gateways. Stop and disable the 'Ignition Gateway' service (or uninstall) before the course; the labs run gateways in Docker only"
fi

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

# --- GitHub from inside a container (required) -----------------------------
section "GitHub from inside a container"
if ! docker_ready; then
  log_warn "Skipping container HTTPS check (Docker not available)" "Fix Docker first, then re-run"
elif ! command -v curl >/dev/null 2>&1; then
  log_warn "Skipping container HTTPS check (curl not found on this machine)" "Install curl and re-run"
else
  # If the host itself can't reach GitHub there's no point probing a container;
  # the fix is upstream of Docker. Exit 60 is the one case worth naming: the
  # corporate CA isn't installed in this OS (on WSL, IT often pushes it to
  # Windows only), which is a different fix from a proxy/firewall problem.
  curl -sS -o /dev/null --max-time 15 https://api.github.com/ 2>/dev/null
  HOST_HTTPS_RC=$?
  if [ "$HOST_HTTPS_RC" -eq 60 ]; then
    log_missing "$REQUIRED" "This machine cannot verify GitHub's certificate (curl exit 60) — the corporate CA isn't trusted by this OS/WSL distro" "Install it here first: see troubleshooting.md → 'TLS interception detected' → 'The host fails too'"
  elif [ "$HOST_HTTPS_RC" -ne 0 ]; then
    log_missing "$REQUIRED" "This machine cannot reach https://api.github.com (curl exit $HOST_HTTPS_RC)" "Check your internet connection and proxy settings, then re-run"
  else
    # Proxy env vars are worth a note: Docker Desktop does not pass them into
    # containers unless configured in Settings → Resources → Proxies. Strip any
    # user:password@ — the report gets pasted into Discord.
    for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
      if [ -n "${!v:-}" ]; then
        log_info "$v is set on this machine ($(printf '%s' "${!v}" | sed -E 's#://[^@/]*@#://***@#')) — containers only inherit it if Docker is configured for the proxy"
        break
      fi
    done

    # Only pull when the image isn't cached, so re-runs stay fast and offline-ish.
    if ! docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 \
       && ! docker pull "$CURL_IMAGE" >/dev/null 2>&1; then
      log_warn "Skipping container HTTPS check (could not pull $CURL_IMAGE)" "If the Ignition image pull below also fails, fix that first; otherwise re-run"
    else
      say "  Probing GitHub over HTTPS from a throwaway container..."
      CONTAINER_HTTPS_FAILED_HOST=""
      CONTAINER_HTTPS_RC=0
      for host in $GITHUB_HOSTS; do
        # Capture the status explicitly: inside `if ! cmd` $? is the negation.
        container_https_probe "$host"
        CONTAINER_HTTPS_RC=$?
        if [ "$CONTAINER_HTTPS_RC" -ne 0 ]; then
          CONTAINER_HTTPS_FAILED_HOST="$host"
          break
        fi
      done

      if [ -z "$CONTAINER_HTTPS_FAILED_HOST" ]; then
        log_pass "Containers can reach GitHub over HTTPS ($GITHUB_HOSTS)"
      elif [ "$CONTAINER_HTTPS_RC" -eq 60 ]; then
        # 60 = CURLE_PEER_FAILED_VERIFICATION: the transport works, but the
        # certificate the container sees isn't signed by a CA it trusts. Since
        # the host just reached GitHub fine, that's the TLS-interception
        # signature: the corporate root CA is on the laptop but not in the image.
        ISSUER="$(container_cert_issuer "$CONTAINER_HTTPS_FAILED_HOST")"
        if [ -d "$CORP_CA_FILE" ]; then
          # Docker creates a *directory* at a bind-mount source that doesn't
          # exist — the classic result of enabling the compose override before
          # exporting the certificate.
          log_missing "$REQUIRED" "TLS interception detected, and $CORP_CA_FILE is a directory, not a certificate (issuer: ${ISSUER:-unknown})" "Docker created it when the runner override ran before the cert existed. 'rm -r $CORP_CA_FILE', then export the certificate there — see troubleshooting.md → 'TLS interception detected'"
        elif [ ! -f "$CORP_CA_FILE" ]; then
          log_missing "$REQUIRED" "TLS interception detected: containers cannot verify the certificate for $CONTAINER_HTTPS_FAILED_HOST (issuer: ${ISSUER:-unknown})" "A corporate proxy re-signs HTTPS traffic and containers don't trust its CA. See troubleshooting.md → 'TLS interception detected'"
        elif ! corp_ca_has_root; then
          log_missing "$REQUIRED" "TLS interception detected: $CORP_CA_FILE has no self-signed root certificate in it (issuer seen: ${ISSUER:-unknown})" "You exported an intermediate. The runner needs the ROOT: the topmost, self-signed certificate of the chain — see troubleshooting.md → 'TLS interception detected'"
        else
          # The student has done the fix. Re-probe *every* host trusting the
          # corporate CA — a proxy can intercept one host and block another.
          CA_FAILED_HOST=""
          CA_RC=0
          for host in $GITHUB_HOSTS; do
            container_https_probe_with_ca "$host"
            CA_RC=$?
            if [ "$CA_RC" -ne 0 ]; then
              CA_FAILED_HOST="$host"
              break
            fi
          done
          if [ -z "$CA_FAILED_HOST" ]; then
            log_pass "Containers can reach GitHub over HTTPS using your corporate CA ($CORP_CA_FILE; proxy issuer: ${ISSUER:-unknown})"
            log_info "Remember the docker-compose.corp-ca.yaml override for the Lab 06 / capstone runner — see troubleshooting.md → 'TLS interception detected'"
          elif [ "$CA_RC" -eq 60 ]; then
            log_missing "$REQUIRED" "TLS interception detected: $CORP_CA_FILE does not make $CA_FAILED_HOST verify (issuer: ${ISSUER:-unknown})" "Wrong certificate, or a different CA is used for this host. Export the root named as issuer above — see troubleshooting.md → 'TLS interception detected'"
          else
            log_missing "$REQUIRED" "Even with your corporate CA, containers cannot reach https://$CA_FAILED_HOST (curl exit $CA_RC)" "The proxy trusts fine but this host is blocked or unreachable from containers. See troubleshooting.md → 'Containers cannot reach GitHub'"
          fi
        fi
      else
        log_missing "$REQUIRED" "Containers cannot reach https://$CONTAINER_HTTPS_FAILED_HOST (curl exit $CONTAINER_HTTPS_RC) although this machine can" "Docker's network isn't getting out. Configure the proxy in Docker Desktop → Settings → Resources → Proxies, or see troubleshooting.md → 'Containers cannot reach GitHub'"
      fi
    fi
  fi
fi

# --- Host ports (required) -------------------------------------------------
# The labs publish fixed ports. Rather than reading the host's listener table
# (which on WSL2 can't see Windows programs), bind them all through Docker's
# real publish path with a container that exits immediately — if a port is
# taken, the run fails naming it. A locally installed PostgreSQL (5432) or
# Ignition (8088) are the usual culprits.
section "Host ports"
if ! docker_ready; then
  log_warn "Skipping port check (Docker not available)" "Fix Docker first, then re-run"
elif ! docker image inspect "$CURL_IMAGE" >/dev/null 2>&1; then
  log_warn "Skipping port check ($CURL_IMAGE not available)" "Re-run once the container HTTPS check above passes"
else
  PORT_ARGS=()
  for port in $LAB_PORTS; do PORT_ARGS+=(-p "$port:$port"); done
  if docker run --rm "${PORT_ARGS[@]}" "$CURL_IMAGE" --version >/dev/null 2>&1; then
    log_pass "Lab ports are free ($LAB_PORTS)"
  else
    BUSY_PORTS=""
    for port in $LAB_PORTS; do
      if ! docker run --rm -p "$port:$port" "$CURL_IMAGE" --version >/dev/null 2>&1; then
        owner="$(port_owner "$port")"
        BUSY_PORTS="$BUSY_PORTS $port${owner:+ ($owner)}"
      fi
    done
    log_missing "$REQUIRED" "Port(s) already in use:${BUSY_PORTS:- (could not tell which)}" "Stop whatever is listening: 'docker compose down' in a lab you left running, or a local Ignition gateway (8088) / PostgreSQL (5432). On WSL2 the owner may be a Windows program that isn't visible from here"
  fi
fi

# --- Course images (required) ----------------------------------------------
section "Course images"
if [ "$NO_PULL" -eq 1 ]; then
  log_info "Skipping image pulls (--no-pull) — relying on locally cached images"
elif ! docker_ready; then
  log_warn "Skipping image pulls (Docker not available)" "Fix Docker first, then re-run"
else
  say "  Pulling all course images (several GB on first run — this is the slow step)..."
  FAILED_IMAGES=""
  for img in $COURSE_IMAGES; do
    say "  · $img"
    docker pull "$img" >/dev/null 2>&1 || FAILED_IMAGES="$FAILED_IMAGES $img"
  done
  if [ -z "$FAILED_IMAGES" ]; then
    log_pass "All course images pulled ($COURSE_IMAGES)"
  else
    log_missing "$REQUIRED" "Could not pull:$FAILED_IMAGES" "Check internet connectivity and Docker Hub access; corporate firewalls sometimes block this. If only some failed, you may have hit Docker Hub's anonymous rate limit — 'docker login' and re-run"
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
