# Guide

[فارسی](guide.fa.md) · [Back to README](../README.md)

## Contents

1. [Concepts](#concepts)
2. [Step-by-step setup](#step-by-step-setup)
3. [Changing ports and IPs](#changing-ports-and-ips)
4. [Several tunnels on one server](#several-tunnels-on-one-server)
5. [Offline install](#offline-install)
6. [Speed tuning](#speed-tuning)
7. [Security](#security)
8. [Files and services](#files-and-services)
9. [Updating and removing](#updating-and-removing)

---

## Concepts

| Term | Meaning |
|---|---|
| **Iran / entry** (`iran`) | The server users connect to. It *listens*: the tunnel port + the forwarded ports. |
| **Foreign / exit** (`kharej`) | The server abroad with the real service. It *dials* the Iran server. |
| **Tunnel port** | The port on the Iran server that the foreign server connects to (default `7001`). It carries the tunnel itself — users never use it. |
| **Forwarded ports** | The ports users connect to on the Iran server. Each is mapped to a port on the foreign side. |
| **Token** | Shared secret. Both ends must have exactly the same one. |

Always set up the **Iran side first** (it generates the token), then the foreign side.

## Step-by-step setup

### Iran server

```bash
sudo ./bpt.sh install iran \
  --port 7001 \
  --ports "80,443,2053=127.0.0.1:2096,10000-10009" \
  --udp yes
```

What it does, in order:

1. Downloads the BackPack release for your CPU and verifies `SHA256SUMS`.
2. Creates `/etc/backpack/bpt.toml` (mode `600`) with a random token.
3. Creates and starts the systemd unit `backpack-bpt.service`.
4. Opens the tunnel port and forwarded ports in **ufw** or **firewalld** if one is active. Otherwise it tells you which ports to open (cloud firewalls / security groups are *not* touched — open them in your provider's panel).
5. Prints the exact command to run on the foreign server.

### Foreign server

```bash
sudo ./bpt.sh install kharej --server IRAN_IP:7001 --token <TOKEN>
```

Options: `--pool 8` (number of ready connections; raise for many parallel users).

### Verify

```bash
sudo ./bpt.sh status         # both servers: look for "control channel established"
sudo ./bpt.sh logs           # live logs
```

## Changing ports and IPs

**Forwarded ports** (Iran server):

```bash
sudo ./bpt.sh ports                                  # show
sudo ./bpt.sh ports --set "80,443=127.0.0.1:2096"    # replace the whole list
```

The list is rewritten, firewall ports are opened, and the tunnel restarts (existing connections drop for a moment).

**Iran IP changed** (for example the old IP was blocked and you got a new one) — on the **foreign** server:

```bash
sudo ./bpt.sh set-server NEW_IP          # keeps the current port
sudo ./bpt.sh set-server NEW_IP:7001     # or set both
```

Nothing changes on the Iran side: it listens on all addresses. If you run **fail2ban** on the foreign server, whitelist the new IP too (see [Security](#security)).

**Tunnel port changed:**

1. Iran: `sudo ./bpt.sh install iran --force --port NEWPORT --ports "<same list>" --token <same token>`
2. Foreign: `sudo ./bpt.sh set-server IRAN_IP:NEWPORT`

**Foreign server IP changed:** nothing to do — it dials the Iran server, so its own IP does not matter.

**Where users connect:** the forwarded ports on the Iran IP. If you use a domain for that IP, only the DNS record changes.

## Several tunnels on one server

Use `--name`. Every tunnel gets its own config and service (`/etc/backpack/NAME.toml`, `backpack-NAME.service`). Tunnel ports and forwarded ports of different tunnels must not collide.

```bash
sudo ./bpt.sh --name vpn1 install iran --port 7001 --ports "443"
sudo ./bpt.sh --name web  install iran --port 7002 --ports "80=127.0.0.1:8080"
sudo ./bpt.sh list
sudo ./bpt.sh --name web status
```

You can also forward to a different foreign host, e.g. a second server that the first foreign server can reach: `--ports "443=203.0.113.10:443"`.

## Offline install

If a server cannot reach GitHub (common in Iran):

1. On a machine that can, download from the [BackPack releases](https://github.com/AminMGMT/BackPack/releases) the file for your CPU, e.g. `backpack_linux_amd64.tar.gz` (check with `uname -m`: `x86_64` → amd64, `aarch64` → arm64).
2. Copy it and `bpt.sh` to the server (`scp`).
3. Run:

```bash
BPT_TARBALL=./backpack_linux_amd64.tar.gz sudo -E ./bpt.sh install iran
# or, if you already have the extracted binary:
BPT_BINARY=./backpack sudo -E ./bpt.sh install iran
```

Offline mode skips the checksum download. Compare the file yourself with `SHA256SUMS` from the release page: `sha256sum backpack_linux_amd64.tar.gz`.

A mirror can also be used: `BP_BASE_URL=https://mirror.example/releases ./bpt.sh install iran`.

## Speed tuning

Long international paths are sensitive to the TCP congestion algorithm and buffer sizes. On **both** servers:

```bash
sudo ./bpt.sh tune
```

This enables **BBR** with `fq` and larger TCP buffers (`/etc/sysctl.d/99-bpt-tune.conf`). Check:

```bash
sysctl net.ipv4.tcp_congestion_control   # bbr
```

If speed is still bad, see [Troubleshooting](troubleshooting.md#slow--lagging).

## Security

* **Token:** 64 random hex characters by default. Anyone with the token who can reach the tunnel port can attach to your tunnel. The config file is `chmod 600`. Do not paste the token in public places.
* **Tunnel port:** only the foreign server needs to reach it. If your provider allows it, restrict it to the foreign IP:

  ```bash
  sudo ufw allow from FOREIGN_IP to any port 7001 proto tcp
  ```

  The script opens the tunnel port for everyone when ufw is active, so afterwards remove that general rule: `sudo ufw delete allow 7001/tcp`.
* **fail2ban on the foreign server:** panels such as 3x-ui may ban an IP that makes many connections. The Iran server looks like one IP carrying *all* your users, so it can get banned and the whole tunnel will lag or die. Whitelist it:

  ```bash
  sudo ./bpt.sh ignore-ip IRAN_IP
  ```
* Forwarded ports are public: anything listening behind them is exposed to the internet. Keep admin panels behind strong passwords or bind them locally (`127.0.0.1:8080=8080`).

## Files and services

| Path | Purpose |
|---|---|
| `/usr/local/bin/backpack` | the BackPack binary |
| `/etc/backpack/NAME.toml` | tunnel config (default name `bpt`), mode 600 |
| `/etc/systemd/system/backpack-NAME.service` | systemd unit (auto-start, restart on failure) |
| `/etc/sysctl.d/99-bpt-tune.conf` | written by `tune` |
| `/etc/fail2ban/jail.d/bpt-ignore.local` | written by `ignore-ip` |

Handy raw commands: `systemctl status backpack-bpt`, `journalctl -u backpack-bpt -f`.

Example configs are in [`examples/`](../examples).

The setup uses the plain `tcp` transport, the simplest and fastest. BackPack also offers other transports (for example WSS and PCK), fallback and load balancing, a layer-3 direct tunnel, a web panel and Telegram monitoring. For those, run `sudo backpack` — the interactive CLI of the engine — or see the [upstream documentation](https://github.com/AminMGMT/BackPack/tree/main/docs). Tunnels created by this script can be edited by hand: change the TOML and `sudo systemctl restart backpack-NAME`.

## Updating and removing

```bash
sudo ./bpt.sh update                      # newest BackPack release, restarts all tunnels made by this script
BP_VERSION=v1.8.5 sudo -E ./bpt.sh update # a specific release

sudo ./bpt.sh uninstall                   # remove tunnel "bpt"
sudo ./bpt.sh --name web uninstall --purge-binary   # also delete the binary
```
