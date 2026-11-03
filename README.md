# BackPack Easy Tunnel

**English** · [فارسی](README.fa.md)

One Bash script that sets up and manages a **reverse TCP tunnel between an Iran server and a foreign server**, using the open-source [BackPack](https://github.com/AminMGMT/BackPack) engine.

- Interactive **menu** (English / فارسی) *and* a scriptable command line.
- Change **forwarded ports**, the **Iran IP** and the **tunnel port** any time, with one command.
- Downloads the official BackPack release and **verifies its SHA-256** before installing.
- Writes the config and a **systemd service** (auto-start, auto-restart), opens the **firewall** (ufw / firewalld), optional **BBR speed tuning** and a **fail2ban whitelist**.
- Several tunnels per server (`--name`), **offline install** for servers that cannot reach GitHub, `--dry-run` to preview everything.

> This project is only an installer/manager. The tunnel engine is BackPack by AminMGMT (AGPL-3.0). This repository does not contain or redistribute it.

---

## How it works

```text
                 users / clients
                       │
                       ▼
             ┌───────────────────┐
             │   IRAN server     │   "entry"  — users connect here
             │  forwarded ports  │   e.g. 80, 443, 2053 ...
             │  tunnel port 7001 │◀──────────────┐
             └───────────────────┘               │  the foreign server DIALS this
                       ▲                         │  (outbound, no open port needed there)
                       │ traffic goes through the tunnel
                       ▼                         │
             ┌───────────────────┐               │
             │  FOREIGN server   │───────────────┘
             │  real service     │   "exit" — x-ui / Xray / web / anything
             └───────────────────┘
```

* The **foreign** server opens the connection **to** Iran (reverse tunnel). It does not need any inbound port.
* The **Iran** server listens on the **tunnel port** (default `7001`) and on every **forwarded port**; traffic to those ports is carried to the foreign server.
* Both sides share a secret **token** (64 hex characters, generated for you).

---

## Requirements

| | |
|---|---|
| OS | Linux with **systemd** (Ubuntu / Debian / CentOS / Rocky …) |
| Access | `root` (or `sudo`) on both servers |
| CPU | x86_64, arm64, armv5/6/7, 386, s390x |
| Network | Iran server: tunnel port + forwarded ports reachable from outside. Foreign server: outbound access to the Iran server's tunnel port. |
| Tools | `bash`, `curl` or `wget`, `tar`, `sha256sum` (all standard) |

---

## Quick start

### 1) Get the script on **both** servers

```bash
curl -fsSLo bpt.sh https://raw.githubusercontent.com/yhsoft4/backpack-easy-tunnel/main/bpt.sh
chmod +x bpt.sh
```

> Iran servers often cannot reach GitHub. Download the file on your PC and copy it with `scp bpt.sh root@IRAN_IP:~/`. See [offline install](docs/guide.md#offline-install).

### 2) Iran server (entry) — run first

Interactive:

```bash
sudo ./bpt.sh
# choose language, then  1) Setup IRAN server
```

Or one command:

```bash
sudo ./bpt.sh install iran --port 7001 --ports "80,443,2053=127.0.0.1:2096"
```

It prints a ready-made command for the foreign server, including the generated token.

### 3) Foreign server (exit)

Paste the command printed in step 2:

```bash
sudo ./bpt.sh install kharej --server IRAN_IP:7001 --token <TOKEN_FROM_STEP_2>
```

### 4) Check

```bash
sudo ./bpt.sh status
```

You should see `control channel established` in the log. Test by connecting to `IRAN_IP:<a forwarded port>`.

---

## Port mappings (`--ports`)

A comma-separated list. The left side is what the **Iran** server listens on; the right side is where the **foreign** server forwards to (as seen from the foreign server).

| Mapping | Meaning |
|---|---|
| `443` | Iran `:443` → foreign `127.0.0.1:443` |
| `443=2096` | Iran `:443` → foreign `127.0.0.1:2096` |
| `443=127.0.0.1:2096` | same, written out |
| `443=10.0.0.5:8443` | Iran `:443` → another host the foreign server can reach |
| `10000-10009` | a range, each port to the same port |
| `10000-10009=20000-20009` | a range, shifted |
| `443=10.0.0.1:80\|10.0.0.2:80` | two backends, health-checked and balanced |
| `127.0.0.1:8080=8080` | listen only on the local machine |

> **A bare port is not "any port".** `443` requires something to be listening on `127.0.0.1:443` on the foreign server. If your panel is on `2096` there, write `443=127.0.0.1:2096`.

The full syntax is documented upstream: [BackPack port mappings](https://github.com/AminMGMT/BackPack/blob/main/docs/port-mappings.md).

---

## Changing things later

| I want to… | Where | Command |
|---|---|---|
| change forwarded ports | Iran | `sudo ./bpt.sh ports --set "80,443=127.0.0.1:2096"` |
| see current ports | Iran | `sudo ./bpt.sh ports` |
| the Iran server got a **new IP** (or a domain) | foreign | `sudo ./bpt.sh set-server NEW_IP[:PORT]` |
| change the tunnel port | both | re-run `install iran --force --port N --token <same>` then `set-server IRAN_IP:N` on the foreign side |
| rotate the token | both | `install … --force --token NEWTOKEN` on both sides |

> Tip: use a **domain name** for the Iran server (`--server your.domain.example:7001`). When its IP changes you only update the DNS record. The foreign side dials the name again on every reconnect; if it does not pick up the new IP after the DNS TTL, run `sudo ./bpt.sh restart` there.

---

## All commands

```text
./bpt.sh [--name NAME] [--lang en|fa] [--yes] [--force] [--dry-run] <command>

(no command)               interactive menu
install iran               entry side:  --port --bind --ports --token --udp --transport
install kharej             exit side:   --server --token --pool
status | start | stop | restart | logs
ports [--set "LIST"]       show / change forwarded ports (Iran)
set-server IP[:PORT]       change the Iran address (foreign)
show [--reveal]            print the config (token hidden unless --reveal)
list                       tunnels created by this script
tune                       BBR + larger TCP buffers (run on both servers)
ignore-ip IP               fail2ban: never ban the tunnel peer
update                     update BackPack, restart tunnels
uninstall [--purge-binary] remove this tunnel
```

Environment variables: `BPT_TARBALL`, `BPT_BINARY` (offline), `BP_VERSION` (pin a release, e.g. `v1.8.5`), `BP_BASE_URL` (mirror), `BPT_SKIP_VERIFY=1` (not recommended), `BPT_LANG`.

Preview without changing anything: add `--dry-run` (also `BPT_ROOT=/tmp/test` writes into a scratch directory).

---

## More documentation

- [Guide](docs/guide.md) — multiple tunnels, offline install, speed tuning, security, files and services
- [Troubleshooting](docs/troubleshooting.md) — symptom → cause → fix
- فارسی: [راهنما](docs/guide.fa.md) · [عیب‌یابی](docs/troubleshooting.fa.md)

## Notes & disclaimer

- Use this only on servers you own or are authorised to manage, and follow the laws that apply to you. The authors take no responsibility for misuse.
- Keep the **token** secret: anyone who has it and can reach the tunnel port can connect to your tunnel.
- Tested: Ubuntu, x86_64 — install/checksum/config generation and the manager commands (in a sandboxed root), and the same configuration running a live tunnel between a Hetzner (Germany) and an Iranian VPS.

## Credits & license

Tunnel engine: [AminMGMT/BackPack](https://github.com/AminMGMT/BackPack) (AGPL-3.0). This installer script: [MIT](LICENSE).
