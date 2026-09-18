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

## "TLS interception detected" (corporate certificate)

**TL;DR** — your company's proxy re-signs HTTPS traffic. Export its root certificate to
`~/corp-root.crt`, re-run the preflight (it turns green), and in Lab 06 and the capstone add
the small compose override from step 3 so the GitHub Actions runner trusts it too.

### What's going on

Your company runs a proxy (Zscaler, Netskope, Palo Alto GlobalProtect, Cisco Umbrella,
Fortinet, …) that decrypts and re-signs HTTPS traffic. IT pushed the proxy's root
certificate to your operating system, so your browser, `git`, `gh` and even `docker pull`
all work — but a **container** only trusts the CA bundle baked into its image, so anything
that makes an HTTPS call from inside a container fails with
`unable to get local issuer certificate` or `The SSL connection could not be established`.

That matters because the labs run the GitHub Actions runner as a container. Without the
fix, the runner never registers with GitHub and the container restart-loops — usually
discovered on Day 3 when there's no time to sort it out. The preflight's report line tells
you who signed the certificate the container saw (`issuer: …`); if that's your company or
proxy vendor rather than Sectigo/DigiCert, this is the section for you.

### 1. Export the proxy's root certificate

Ask IT for the root CA as a `.crt`/`.pem` file if you can — that's the fastest route.
Otherwise export it yourself. The `issuer:` in your preflight report names the certificate
that signed what the container saw — often an *intermediate* (e.g. "Zscaler Intermediate
Root CA"). You need the **root** above it: the topmost certificate in that chain, the one
that is issued to itself. In the certificate viewer, open the `issuer:` entry, look at its
*Certification Path* / chain, and export the top one. (The preflight checks this and tells
you if you exported an intermediate.)

- **Windows:** `Win+R` → `certmgr.msc` (or `certlm.msc` if it isn't there — IT usually
  installs into the machine store) → *Trusted Root Certification Authorities* →
  *Certificates* → find the entry → right-click → *All Tasks* → *Export…* →
  **Base-64 encoded X.509 (.CER)**. Save it, then copy it into WSL:

  ```bash
  cp /mnt/c/Users/<you>/Downloads/corp-root.cer ~/corp-root.crt
  ```

- **macOS:** open *Keychain Access* → *System* keychain → *Certificates* → find the entry →
  *File* → *Export Items…* → format **Privacy Enhanced Mail (.pem)** → save as `~/corp-root.crt`
- **Linux:** it's usually already under `/usr/local/share/ca-certificates/` or
  `/etc/pki/ca-trust/source/anchors/`; copy it to `~/corp-root.crt`.

The file must be PEM — it should start with `-----BEGIN CERTIFICATE-----`. If it's binary
(DER), convert it:

```bash
openssl x509 -inform der -in corp-root.cer -out ~/corp-root.crt
```

### 2. Re-run the preflight

```bash
./scripts/preflight.sh --no-pull --skip-smoke
```

The script notices `~/corp-root.crt`, probes GitHub again trusting it, and reports
`Containers can reach GitHub over HTTPS using your corporate CA`. If it instead says the
file *"exists but does not make … verify"*, you exported the wrong certificate (an
intermediate, or something unrelated) or it isn't PEM — go back to step 1 and pick the
certificate named as `issuer:`, or the root above it.

Keep `~/corp-root.crt` exactly there: step 3 relies on it.

### 3. Make the labs use it

The only containers in the course that talk to GitHub are the self-hosted runners in
**Lab 06** and the **capstone (Lab 07)**. Everything else — `git`, `gh`, `docker pull`, the
Ignition gateways — works already. So the fix is: get the certificate into the runner
container before it registers.

Create a file called `docker-compose.corp-ca.yaml` next to the lab's `docker-compose.yaml`
(same content for both labs — it's generic and safe to commit; the certificate itself stays
in your home directory):

```yaml
# Opt-in override for laptops behind a TLS-intercepting corporate proxy.
services:
  github-runner:
    volumes:
      # Long syntax on purpose: with the short "src:dst" form Docker silently
      # creates a DIRECTORY at the source when the file is missing.
      - type: bind
        source: ${CORP_CA_FILE:-~/corp-root.crt}
        target: /usr/local/share/ca-certificates/corp-root.crt
        read_only: true
        bind:
          create_host_path: false
    environment:
      # JavaScript actions (actions/checkout etc.) run under the runner's own
      # bundled node, which ignores the system store and needs this pointer.
      NODE_EXTRA_CA_CERTS: /usr/local/share/ca-certificates/corp-root.crt
    # Rebuild the system CA bundle from the mounted cert, prove it is now a
    # trusted root, then hand over to the image's own entrypoint. Overriding
    # entrypoint clears the image's CMD, so it is restated below.
    # ($$@ is compose's escape for a literal $@.)
    entrypoint:
      - /bin/bash
      - -c
      - |
        update-ca-certificates >/dev/null 2>&1
        if ! openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /usr/local/share/ca-certificates/corp-root.crt >/dev/null 2>&1; then
          echo "corp-ca: corp-root.crt was not installed as a trusted root — is it a PEM file containing the self-signed ROOT certificate?" >&2
          exit 1
        fi
        exec /entrypoint.sh "$$@"
      - --
    command: ["./bin/Runner.Listener", "run", "--startuptype", "service"]
```

Then tell compose to layer it on top of the lab's file by adding one line to the lab's `.env`:

```bash
COMPOSE_FILE=docker-compose.yaml:docker-compose.corp-ca.yaml
```

From then on every plain `docker compose up -d` in that lab includes the override — the lab
scripts don't need to know. Verify with:

```bash
docker compose up -d github-runner
docker compose logs github-runner | head -20
```

You should see the GitHub Actions banner and `Runner successfully added`, not an SSL error.
If the container refuses to start with `bind source path does not exist`, `~/corp-root.crt`
isn't there (step 1). If the log's only line is `corp-ca: … was not installed as a trusted
root`, the file isn't PEM or isn't the self-signed root (step 1 again; the preflight tells you
which).

What this covers inside the runner: `Runner.Listener` (registration, job polling), `git`
and `curl`/`gh` in your workflow steps (system CA bundle), and JavaScript actions such as
`actions/checkout` (`NODE_EXTRA_CA_CERTS`). Workflow steps that use `docker` talk to the
host's daemon over the mounted socket, so they already trust the proxy like the host does.

### The host fails too

If the preflight says *"This machine cannot verify GitHub's certificate (curl exit 60)"*,
the proxy's root CA isn't trusted by the operating system the script runs in either. On
Windows that means it was pushed to the Windows certificate store but not into your WSL
distro — which is normal, IT tools don't know about WSL. Install it there once (this is the
one place in the course where `sudo` is legitimate — it's system configuration, not a lab):

```bash
sudo cp ~/corp-root.crt /usr/local/share/ca-certificates/corp-root.crt
sudo update-ca-certificates
```

Re-run the preflight; it will now get past the host check and on to the container probe,
where `~/corp-root.crt` is picked up as described above.

### 4. If you can't export the certificate

Some IT departments won't hand it over. Options, in order of preference:

1. Ask IT to **exempt `*.github.com` and `*.githubusercontent.com` from inspection**
   (a common allow-list request; GitHub publishes the [full list of hosts](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#communication-between-self-hosted-runners-and-github)).
2. Run the labs off the corporate network (home Wi-Fi, phone hotspot) for the days the
   runner is used.
3. Post in `#preflight-help` — the TA can walk through it with you before Day 1.

## "Containers cannot reach GitHub" (although this machine can)

The host reaches GitHub but a container doesn't, and the failure is *not* a certificate
error (typically a timeout or connection refused). Docker's network isn't getting through
your proxy or firewall:

- **Docker Desktop:** Settings → Resources → Proxies → *Manual proxy configuration*, enter the
  same proxy your browser uses, then *Apply & restart*.
- **Linux:** put `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in `~/.docker/config.json` under
  `"proxies": {"default": {…}}` so they're passed into every container.
- **Corporate VPN clients** sometimes block container traffic entirely; try disconnecting the
  VPN and re-running the preflight to confirm.

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
