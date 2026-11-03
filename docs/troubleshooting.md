# Troubleshooting

[فارسی](troubleshooting.fa.md) · [Back to README](../README.md)

First, always collect facts on **both** servers:

```bash
sudo ./bpt.sh status
sudo ./bpt.sh logs            # Ctrl+C to leave
sudo ./bpt.sh show            # token is hidden; compare with --reveal on both sides
```

A healthy foreign-side log contains `control channel established` and `transport tcp is up`; the Iran side shows `control channel successfully established`.

## The tunnel does not connect

| Symptom | Likely cause | Fix |
|---|---|---|
| Foreign log: `connection refused` / `timeout` | Iran tunnel port is closed or wrong | Open the port in ufw **and** the provider's firewall. From the foreign server: `nc -vz IRAN_IP 7001` |
| Never reaches "established", or no useful error | **Token mismatch** (upstream notes it can look like a dead tunnel) | Compare `./bpt.sh show --reveal` on both sides. Re-run the foreign `install --force` with the exact token |
| Worked yesterday, not today | The Iran IP changed or was **blocked** | Check `ping IRAN_IP` / `nc -vz` from abroad. New IP: `./bpt.sh set-server NEW_IP` on the foreign side |
| `nc` from abroad times out but the server is up | Iran provider/ISP filters that path or port | Try another tunnel port (`443`, `8443`, `2053`...). See "Path filtering" below |
| `address already in use` on the Iran side | Another program uses the tunnel or a forwarded port | `ss -ltnp | grep :7001`; pick another port |

## Tunnel is up but users cannot connect

1. **Forwarded port closed:** `ss -ltn | grep ':443 '` on the Iran server should show a listener once the tunnel is up. If it does, open the port in the firewall (ufw **and** the provider's panel); if not, check `./bpt.sh logs` for the reason.
2. **Nothing behind the port:** `443` means the foreign server's `127.0.0.1:443`. On the foreign server check `ss -ltn | grep ':2096 '` and map accordingly (`443=127.0.0.1:2096`). See the note in the README.
3. **UDP services (WireGuard, Hysteria, DNS, games…):** install with `--udp yes` (default) and open the **UDP** firewall ports too.
4. **Backend rejects the connection:** the service sees every user coming from the tunnel (`127.0.0.1`/the exit server). Panels with per-IP limits, IP bans or geo rules may treat all users as one client. Relax those limits for the tunnel source.

## Slow / lagging

Work through these in order:

1. **fail2ban banned the Iran IP** (very common with x-ui/3x-ui): on the foreign server
   `fail2ban-client status` → `fail2ban-client status <jail>`; if the Iran IP is listed, unban and whitelist it:
   ```bash
   sudo fail2ban-client set <jail> unbanip IRAN_IP
   sudo ./bpt.sh ignore-ip IRAN_IP
   ```
2. **Congestion control:** run `sudo ./bpt.sh tune` on **both** servers (BBR + buffers).
3. **Check the raw path** between the servers, outside the tunnel:
   `ping -c 20 IRAN_IP` (loss? jitter?) and `iperf3` if available. High loss/jitter is the network, not the tunnel.
4. **Connection pool:** raise `--pool` on the foreign side (e.g. `--pool 16`) for many parallel users: `sudo ./bpt.sh install kharej --force --server … --token … --pool 16`.
5. **CPU/RAM:** `top` — a tiny VPS can be the limit.
6. **MTU problems** (some sites hang, big pages never load): see upstream [`mss-clamp.md`](https://github.com/AminMGMT/BackPack/blob/main/docs/mss-clamp.md).

### Path filtering

Some routes drop or throttle **TCP in one direction** but let UDP through, or filter specific ports/IPs after a while. Signs: `ping` fine, tunnel connects but is extremely slow only in one direction.

* A reverse tunnel (this script) makes the **foreign** server open the connection to Iran, which often avoids the throttled direction. If it is still bad, change the tunnel port, change the IP, or try another BackPack transport (`sudo backpack` → *Link Test* measures the route and recommends one).
* If the Iran IP is blocked, get a new IP and run `./bpt.sh set-server NEW_IP` on the foreign side (a domain name makes this a DNS-only change).

## Installer problems

| Message | Meaning / fix |
|---|---|
| `download failed` | The server cannot reach GitHub. Use the [offline install](guide.md#offline-install) or a mirror |
| `checksum mismatch - refusing to install` | The file is corrupted or tampered with. Download again; if it persists, do not install |
| `unsupported CPU` | The release has no build for it — build BackPack from source |
| `run as root` | Use `sudo` |
| `tunnel 'X' not found` | Wrong `--name`; `./bpt.sh list` |
| Script prints `[dry-run]` lines | `--dry-run` or `BPT_ROOT` is set; unset it |

## Logs and a clean restart

```bash
sudo ./bpt.sh restart
journalctl -u backpack-bpt --since "10 min ago" --no-pager
```

## Reporting a bug

Open an issue with: the OS (`cat /etc/os-release`), `uname -m`, the output of `./bpt.sh show` (token hidden), and the last 30 log lines from **both** servers. Never post the token.
