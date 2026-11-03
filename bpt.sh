#!/usr/bin/env bash
# bpt.sh - one-file installer / manager for BackPack reverse tunnels (Iran <-> abroad).
# https://github.com/yhsoft4/backpack-easy-tunnel
#
# This script does NOT contain the tunnel engine. It downloads the official BackPack
# release (https://github.com/AminMGMT/BackPack, AGPL-3.0), verifies its SHA-256 checksum,
# writes the TOML config + a systemd unit, and gives you a menu / CLI to change ports and IPs.
#
# Roles
#   iran    = ENTRY server: users connect here; it listens for the tunnel and exposes ports.
#   kharej  = EXIT server (abroad): it DIALS the entry server and forwards to the real service.
set -euo pipefail

SCRIPT_VERSION="1.0.0"
BP_REPO="${BP_REPO:-AminMGMT/BackPack}"
BP_BASE_URL="${BP_BASE_URL:-https://github.com/${BP_REPO}/releases}"
BP_VERSION="${BP_VERSION:-latest}"
ROOT="${BPT_ROOT:-}"
BIN="${BPT_BIN:-${ROOT}/usr/local/bin/backpack}"
CONF_DIR="${ROOT}/etc/backpack"
UNIT_DIR="${ROOT}/etc/systemd/system"
SYSCTL_FILE="${ROOT}/etc/sysctl.d/99-bpt-tune.conf"
F2B_FILE="${ROOT}/etc/fail2ban/jail.d/bpt-ignore.local"
MARK="# managed by bpt.sh"

NAME="bpt"
BPT_TMP=""
trap '[ -n "$BPT_TMP" ] && rm -rf "$BPT_TMP"' EXIT
LANG_UI="${BPT_LANG:-}"
DRY=0
YES=0
FORCE=0
REVEAL=0

# ---------------------------------------------------------------- helpers
say() { if [ "$LANG_UI" = "fa" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
sayn() { if [ "$LANG_UI" = "fa" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
die() { say "ERROR: $1" "خطا: $2" >&2; exit 1; }
warn() { say "WARNING: $1" "هشدار: $2" >&2; }
is_tty() { [ -t 0 ] && [ "$YES" = 0 ]; }

ask() { # ask "prompt en" "prompt fa" default
  local var
  if ! is_tty; then printf '%s' "$3"; return; fi
  read -r -p "$(sayn "$1" "$2") [$3]: " var || true
  printf '%s' "${var:-$3}"
}

confirm() { # confirm "en" "fa"  -> 0 yes / 1 no
  if [ "$YES" = 1 ] || ! [ -t 0 ]; then return 0; fi
  local a
  read -r -p "$(sayn "$1" "$2") [y/N]: " a || true
  case "$a" in y | Y | yes | YES | ب | بله) return 0 ;; *) return 1 ;; esac
}

need_root() {
  [ "$DRY" = 1 ] && return 0
  [ -n "$ROOT" ] && return 0
  [ "$(id -u)" = 0 ] || die "run as root (sudo)." "با کاربر root (sudo) اجرا کنید."
}

run() { # run a system-changing command, or just print it in --dry-run
  if [ "$DRY" = 1 ] || [ -n "$ROOT" ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

write_file() { # write_file path mode  (content on stdin)
  local path="$1" mode="${2:-644}"
  if [ "$DRY" = 1 ]; then
    printf '[dry-run] --- %s (mode %s) ---\n' "$path" "$mode"
    cat
    printf '[dry-run] --- end ---\n'
  else
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    chmod "$mode" "$path"
  fi
}

valid_name() { [[ "$1" =~ ^[a-z0-9_-]{1,24}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
conf_path() { printf '%s/%s.toml' "$CONF_DIR" "${1:-$NAME}"; }
unit_name() { printf 'backpack-%s.service' "${1:-$NAME}"; }

cfg_get() { # cfg_get file key -> raw value without surrounding quotes
  [ -f "$1" ] || return 0
  sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1" | head -1 | sed 's/^"//; s/"$//'
}

cfg_set() { # cfg_set file key raw_value
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '{ if ($0 ~ "^" k "[ \t]*=") print k " = " v; else print }' "$f" >"$tmp"
  cat "$tmp" >"$f"
  rm -f "$tmp"
}

public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# "80,443=127.0.0.1:2096,10000-10009" -> ["80","443=127.0.0.1:2096","10000-10009"]
ports_to_toml() {
  local list="$1" out="" item
  IFS=',' read -r -a arr <<<"$list"
  for item in "${arr[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [ -n "$item" ] || continue
    out+="\"$item\","
  done
  [ -n "$out" ] || die "empty port list." "فهرست پورت‌ها خالی است."
  printf '[%s]' "${out%,}"
}

# toml array -> plain comma list
toml_to_ports() { printf '%s' "$1" | tr -d '[]" ' ; }

# listening ports (numbers) from a mapping list, for the firewall. Ranges are expanded (max 2000).
listen_ports() {
  local list="$1" item left lo hi p n=0
  IFS=',' read -r -a arr <<<"$list"
  for item in "${arr[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    left="${item%%=*}"
    left="${left##*:}"
    if [[ "$left" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
      for ((p = lo; p <= hi && n < 2000; p++)); do printf '%s\n' "$p"; n=$((n + 1)); done
    elif valid_port "$left"; then
      printf '%s\n' "$left"
    fi
  done
}

# ---------------------------------------------------------------- binary
detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    armv7l | armv7) echo armv7 ;;
    armv6l) echo armv6 ;;
    armv5*) echo armv5 ;;
    i386 | i686) echo 386 ;;
    s390x) echo s390x ;;
    *) die "unsupported CPU: $(uname -m)" "معماری پردازنده پشتیبانی نمی‌شود: $(uname -m)" ;;
  esac
}

fetch() { # fetch url out
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "curl or wget is required." "curl یا wget لازم است."; fi
}

install_binary() {
  if [ -x "$BIN" ] && [ "$FORCE" = 0 ]; then
    say "BackPack is already installed: $("$BIN" -v 2>/dev/null | head -1)" "BackPack از قبل نصب است: $("$BIN" -v 2>/dev/null | head -1)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    say "[dry-run] would download BackPack $BP_VERSION for $(detect_arch) and verify its SHA-256." "[dry-run] BackPack نسخه $BP_VERSION برای $(detect_arch) دانلود و SHA-256 آن بررسی می‌شد."
    return 0
  fi
  local tmp arch file base
  tmp="$(mktemp -d)"
  BPT_TMP="$tmp"
  arch="$(detect_arch)"
  file="backpack_linux_${arch}.tar.gz"
  if [ -n "${BPT_BINARY:-}" ]; then
    [ -f "$BPT_BINARY" ] || die "BPT_BINARY not found." "فایل BPT_BINARY پیدا نشد."
    mkdir -p "$(dirname "$BIN")"
    install -m 755 "$BPT_BINARY" "$BIN"
    say "Installed binary from $BPT_BINARY" "باینری از $BPT_BINARY نصب شد"
    return 0
  fi
  if [ -n "${BPT_TARBALL:-}" ]; then
    cp "$BPT_TARBALL" "$tmp/$file"
  else
    if [ "$BP_VERSION" = latest ]; then base="$BP_BASE_URL/latest/download"; else base="$BP_BASE_URL/download/$BP_VERSION"; fi
    say "Downloading $file ..." "در حال دانلود $file ..."
    fetch "$base/$file" "$tmp/$file" || die "download failed. Offline? Use BPT_TARBALL=/path/$file (see docs)." "دانلود ناموفق بود. سرور به GitHub دسترسی ندارد؟ از BPT_TARBALL=/path/$file استفاده کنید (راهنما را ببینید)."
    if [ "${BPT_SKIP_VERIFY:-0}" != 1 ]; then
      fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not fetch SHA256SUMS." "فایل SHA256SUMS دریافت نشد."
      (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null) || die "checksum mismatch - refusing to install." "جمع کنترلی (checksum) نمی‌خواند - نصب انجام نشد."
      say "Checksum OK." "checksum درست است."
    fi
  fi
  tar -xzf "$tmp/$file" -C "$tmp"
  [ -f "$tmp/backpack" ] || die "archive does not contain 'backpack'." "فایل backpack داخل آرشیو نیست."
  mkdir -p "$(dirname "$BIN")"
  install -m 755 "$tmp/backpack" "$BIN"
  say "Installed $("$BIN" -v 2>/dev/null | head -1) -> $BIN" "نصب شد: $("$BIN" -v 2>/dev/null | head -1) -> $BIN"
}

# ---------------------------------------------------------------- config rendering
render_server() { # name bind_addr transport token ports_toml udp
  cat <<EOF
$MARK (role: iran)
[server]
bind_addr = "$2"
transport = "$3"
token = "$4"
ports = $5
accept_udp = $6
nodelay = true
keepalive_period = 20
heartbeat = 10
log_level = "info"
EOF
}

render_client() { # name remote_addr transport token pool
  cat <<EOF
$MARK (role: kharej)
[client]
remote_addr = "$2"
transport = "$3"
token = "$4"
nodelay = true
keepalive_period = 20
connection_pool = $5
retry_interval = 3
dial_timeout = 10
log_level = "info"
EOF
}

render_unit() {
  cat <<EOF
[Unit]
Description=Backpack tunnel $NAME
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN -c $(conf_path)
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  write_file "$UNIT_DIR/$(unit_name)" 644 < <(render_unit)
  run systemctl daemon-reload
  run systemctl enable --now "$(unit_name)"
}

open_firewall() { # open_firewall "tcp|udp" ports...
  local proto="$1"; shift
  local ports=("$@") p
  [ "${#ports[@]}" -gt 0 ] || return 0
  if [ "$DRY" = 1 ] || [ -n "$ROOT" ]; then printf '[dry-run] firewall: allow %s %s\n' "$proto" "${ports[*]}"; return 0; fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${ports[@]}"; do ufw allow "$p/$proto" >/dev/null; done
    say "ufw: opened $proto ${ports[*]}" "ufw: پورت‌های $proto ${ports[*]} باز شد"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="$p/$proto" >/dev/null; done
    firewall-cmd --reload >/dev/null
    say "firewalld: opened $proto ${ports[*]}" "firewalld: پورت‌های $proto ${ports[*]} باز شد"
  else
    say "No active ufw/firewalld found. Make sure these ports are reachable ($proto): ${ports[*]}" "ufw/firewalld فعال نیست. مطمئن شوید این پورت‌ها ($proto) باز هستند: ${ports[*]}"
  fi
}

# ---------------------------------------------------------------- commands
cmd_install() {
  local role="${1:-}"; shift || true
  local port="" bind="0.0.0.0" ports="" token="" transport="tcp" udp="" server="" pool="8" arg
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --name) NAME="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --bind) bind="$2"; shift 2 ;;
      --ports) ports="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      --transport) transport="$2"; shift 2 ;;
      --udp) udp="$2"; shift 2 ;;
      --server) server="$2"; shift 2 ;;
      --pool) pool="$2"; shift 2 ;;
      *) die "unknown option: $arg" "گزینه ناشناخته: $arg" ;;
    esac
  done
  valid_name "$NAME" || die "bad --name (a-z 0-9 _ -)." "مقدار --name نامعتبر است (فقط a-z 0-9 _ -)."
  case "$role" in iran | kharej) ;; *) die "role must be 'iran' or 'kharej'." "نقش باید iran یا kharej باشد." ;; esac
  need_root
  [ -f "$(conf_path)" ] && [ "$FORCE" = 0 ] && ! confirm "Tunnel '$NAME' already exists. Overwrite?" "تانل '$NAME' از قبل وجود دارد. بازنویسی شود؟" && die "aborted." "لغو شد."

  install_binary

  if [ "$role" = iran ]; then
    [ -n "$port" ] || port="$(ask "Tunnel port (the kharej server dials this)" "پورت تانل (سرور خارج به این وصل می‌شود)" 7001)"
    valid_port "$port" || die "invalid tunnel port." "پورت تانل نامعتبر است."
    [ -n "$ports" ] || ports="$(ask "Forwarded ports, e.g. 80,443,2053=127.0.0.1:2096,10000-10009" "پورت‌های فوروارد، مثل 80,443,2053=127.0.0.1:2096,10000-10009" "80,443")"
    [ -n "$token" ] || token="$(gen_token)"
    [ -n "$udp" ] || udp="$(ask "Carry UDP as well as TCP? (yes/no)" "UDP هم عبور کند؟ (yes/no)" yes)"
    case "$udp" in yes | y | true | 1) udp=true ;; *) udp=false ;; esac
    write_file "$(conf_path)" 600 < <(render_server "$NAME" "$bind:$port" "$transport" "$token" "$(ports_to_toml "$ports")" "$udp")
    enable_service
    # shellcheck disable=SC2046
    open_firewall tcp "$port" $(listen_ports "$ports")
    # shellcheck disable=SC2046
    [ "$udp" = true ] && open_firewall udp $(listen_ports "$ports") || true
    local ip; ip="$(public_ip)"
    echo
    say "=== Iran (entry) side is ready ===" "=== سمت ایران (ورودی) آماده است ==="
    say "Now run this on the foreign (exit) server:" "حالا این دستور را روی سرور خارج اجرا کنید:"
    echo
    echo "  sudo ./bpt.sh install kharej --name $NAME --server ${ip:-IRAN_SERVER_IP}:$port --token $token"
    echo
    say "Token (keep it secret): $token" "توکن (محرمانه نگه دارید): $token"
  else
    [ -n "$server" ] || server="$(ask "Iran server address ip:port (or domain:port)" "آدرس سرور ایران به شکل ip:port (یا دامنه:port)" "")"
    [ -n "$server" ] || die "--server is required." "گزینه --server الزامی است."
    [[ "$server" == *:* ]] || server="$server:7001"
    [ -n "$token" ] || token="$(ask "Token printed on the Iran server" "توکنی که روی سرور ایران چاپ شد" "")"
    [ -n "$token" ] || die "--token is required." "گزینه --token الزامی است."
    write_file "$(conf_path)" 600 < <(render_client "$NAME" "$server" "$transport" "$token" "$pool")
    enable_service
    echo
    say "=== Foreign (exit) side is ready ===" "=== سمت خارج آماده است ==="
    say "Check: ./bpt.sh status   (look for 'control channel established')" "بررسی: ./bpt.sh status   (دنبال 'control channel established' بگردید)"
  fi
}

cmd_status() {
  local f; f="$(conf_path)"
  [ -f "$f" ] || die "tunnel '$NAME' not found." "تانل '$NAME' پیدا نشد."
  if grep -q '^\[server\]' "$f"; then say "Role: iran (entry)  bind=$(cfg_get "$f" bind_addr)  ports=$(toml_to_ports "$(cfg_get "$f" ports)")" "نقش: ایران (ورودی)  bind=$(cfg_get "$f" bind_addr)  پورت‌ها=$(toml_to_ports "$(cfg_get "$f" ports)")"
  else say "Role: kharej (exit)  server=$(cfg_get "$f" remote_addr)" "نقش: خارج  سرور=$(cfg_get "$f" remote_addr)"; fi
  systemctl is-active "$(unit_name)" 2>/dev/null || true
  journalctl -u "$(unit_name)" -n 8 --no-pager 2>/dev/null | cut -c1-180 || true
}

cmd_service() { need_root; run systemctl "$1" "$(unit_name)"; }
cmd_logs() { journalctl -u "$(unit_name)" -f -n 50; }

cmd_ports() { # ports --set "list" | ports (show)
  local f; f="$(conf_path)"
  [ -f "$f" ] || die "tunnel '$NAME' not found." "تانل '$NAME' پیدا نشد."
  grep -q '^\[server\]' "$f" || die "ports can only be changed on the Iran (entry) side." "پورت‌ها فقط روی سمت ایران (ورودی) قابل تغییرند."
  if [ "${1:-}" != "--set" ]; then
    say "Current ports: $(toml_to_ports "$(cfg_get "$f" ports)")" "پورت‌های فعلی: $(toml_to_ports "$(cfg_get "$f" ports)")"
    return 0
  fi
  need_root
  local new="${2:-}"
  [ -n "$new" ] || die "usage: ports --set \"80,443=127.0.0.1:2096\"" "نحوه استفاده: ports --set \"80,443=127.0.0.1:2096\""
  cfg_set "$f" ports "$(ports_to_toml "$new")"
  # shellcheck disable=SC2046
  open_firewall tcp $(listen_ports "$new")
  [ "$(cfg_get "$f" accept_udp)" = true ] && { # shellcheck disable=SC2046
    open_firewall udp $(listen_ports "$new"); } || true
  run systemctl restart "$(unit_name)"
  say "Ports updated and tunnel restarted." "پورت‌ها به‌روز شد و تانل ری‌استارت شد."
}

cmd_server() { # set-server ip[:port]  (kharej side)
  local f; f="$(conf_path)"
  [ -f "$f" ] || die "tunnel '$NAME' not found." "تانل '$NAME' پیدا نشد."
  grep -q '^\[client\]' "$f" || die "set-server is for the foreign (kharej) side." "set-server مخصوص سمت خارج است."
  need_root
  local new="${1:-}" old
  [ -n "$new" ] || die "usage: set-server NEW_IP[:PORT]" "نحوه استفاده: set-server IP_جدید[:PORT]"
  old="$(cfg_get "$f" remote_addr)"
  [[ "$new" == *:* ]] || new="$new:${old##*:}"
  cfg_set "$f" remote_addr "\"$new\""
  run systemctl restart "$(unit_name)"
  say "Iran address changed: $old -> $new (tunnel restarted)." "آدرس ایران عوض شد: $old -> $new (تانل ری‌استارت شد)."
  say "Tip: if you run fail2ban, also run: ./bpt.sh ignore-ip ${new%%:*}" "نکته: اگر fail2ban دارید این را هم بزنید: ./bpt.sh ignore-ip ${new%%:*}"
}

cmd_show() {
  local f; f="$(conf_path)"
  [ -f "$f" ] || die "tunnel '$NAME' not found." "تانل '$NAME' پیدا نشد."
  if [ "$REVEAL" = 1 ]; then cat "$f"; else sed 's/^token = ".*"/token = "********** (use --reveal)"/' "$f"; fi
}

cmd_list() {
  local f n st found=0
  for f in "$CONF_DIR"/*.toml; do
    [ -f "$f" ] || continue
    grep -q "$MARK" "$f" || continue
    n="$(basename "$f" .toml)"
    found=1
    st="$(systemctl is-active "backpack-$n.service" 2>/dev/null || true)"
    printf '%-14s %-8s %s\n' "$n" "$(grep -q '^\[server\]' "$f" && echo iran || echo kharej)" "${st:-unknown}"
  done
  [ "$found" = 1 ] || say "No tunnels created by bpt.sh." "تانلی با bpt.sh ساخته نشده است."
}

cmd_tune() {
  need_root
  modprobe tcp_bbr 2>/dev/null || true
  write_file "$SYSCTL_FILE" 644 <<'EOF'
# bpt.sh: throughput tuning for long, lossy Iran <-> abroad paths
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 131072 16777216
net.ipv4.tcp_slow_start_after_idle=0
EOF
  run sysctl -p "$SYSCTL_FILE"
  say "Tuning applied (BBR + larger buffers). Run this on BOTH servers." "تنظیمات سرعت اعمال شد (BBR + بافر بزرگ‌تر). روی هر دو سرور اجرا کنید."
}

cmd_ignore_ip() { # fail2ban whitelist
  need_root
  local ip="${1:-}"
  [ -n "$ip" ] || die "usage: ignore-ip IP" "نحوه استفاده: ignore-ip IP"
  command -v fail2ban-client >/dev/null 2>&1 || warn "fail2ban is not installed; file will still be written." "fail2ban نصب نیست؛ فایل به‌هرحال نوشته می‌شود."
  write_file "$F2B_FILE" 644 <<EOF
# bpt.sh: never ban the tunnel peer (a ban makes the tunnel and every user behind it lag or die)
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $ip
EOF
  run fail2ban-client reload
  say "fail2ban now ignores $ip" "fail2ban از این به بعد $ip را بن نمی‌کند"
}

cmd_update() {
  need_root
  FORCE=1
  install_binary
  local f n
  for f in "$CONF_DIR"/*.toml; do
    [ -f "$f" ] || continue
    grep -q "$MARK" "$f" || continue
    n="$(basename "$f" .toml)"
    run systemctl restart "backpack-$n.service"
  done
  say "Updated and restarted all bpt.sh tunnels." "به‌روزرسانی شد و همه‌ی تانل‌های bpt.sh ری‌استارت شدند."
}

cmd_uninstall() {
  need_root
  local purge="${1:-}"
  confirm "Remove tunnel '$NAME'?" "تانل '$NAME' حذف شود؟" || die "aborted." "لغو شد."
  run systemctl disable --now "$(unit_name)" || true
  if [ "$DRY" = 1 ]; then printf '[dry-run] rm %s %s\n' "$UNIT_DIR/$(unit_name)" "$(conf_path)"; else rm -f "$UNIT_DIR/$(unit_name)" "$(conf_path)"; fi
  run systemctl daemon-reload
  if [ "$purge" = "--purge-binary" ]; then run rm -f "$BIN"; fi
  say "Tunnel '$NAME' removed." "تانل '$NAME' حذف شد."
}

# ---------------------------------------------------------------- menu
choose_lang() {
  [ -n "$LANG_UI" ] && return 0
  if is_tty; then
    local a
    read -r -p "Language / زبان  [1] English  [2] فارسی : " a || true
    [ "$a" = 2 ] && LANG_UI=fa || LANG_UI=en
  else
    LANG_UI=en
  fi
}

menu() {
  while true; do
    echo
    say "=== BackPack Easy Tunnel  v$SCRIPT_VERSION  (tunnel: $NAME) ===" "=== نصب‌کننده ساده تانل BackPack  نسخه $SCRIPT_VERSION  (تانل: $NAME) ==="
    say " 1) Setup IRAN server (entry)        " " ۱) راه‌اندازی سرور ایران (ورودی)"
    say " 2) Setup FOREIGN server (exit)      " " ۲) راه‌اندازی سرور خارج (خروجی)"
    say " 3) Status                           " " ۳) وضعیت"
    say " 4) Live logs                        " " ۴) لاگ زنده"
    say " 5) Restart                          " " ۵) ری‌استارت"
    say " 6) Change forwarded ports (Iran)    " " ۶) تغییر پورت‌های فوروارد (ایران)"
    say " 7) Change Iran IP/port (foreign)    " " ۷) تغییر آی‌پی/پورت ایران (سرور خارج)"
    say " 8) Speed tuning (BBR)               " " ۸) بهینه‌سازی سرعت (BBR)"
    say " 9) Show config                      " " ۹) نمایش تنظیمات"
    say "10) fail2ban whitelist for peer IP   " "۱۰) سفیدلیست fail2ban برای آی‌پی طرف مقابل"
    say "11) Update BackPack                  " "۱۱) به‌روزرسانی BackPack"
    say "12) List tunnels                     " "۱۲) فهرست تانل‌ها"
    say "13) Uninstall tunnel                 " "۱۳) حذف تانل"
    say " n) Change tunnel name   l) Language   0) Exit" " n) تغییر نام تانل   l) زبان   0) خروج"
    local c v
    read -r -p "> " c || exit 0
    case "$c" in
      1 | ۱) cmd_install iran ;;
      2 | ۲) cmd_install kharej ;;
      3 | ۳) cmd_status ;;
      4 | ۴) cmd_logs ;;
      5 | ۵) cmd_service restart ;;
      6 | ۶) cmd_ports; v="$(ask "New port list" "فهرست جدید پورت‌ها" "")"; [ -n "$v" ] && cmd_ports --set "$v" ;;
      7 | ۷) v="$(ask "New Iran ip[:port]" "آی‌پی[:پورت] جدید ایران" "")"; [ -n "$v" ] && cmd_server "$v" ;;
      8 | ۸) cmd_tune ;;
      9 | ۹) cmd_show ;;
      10 | ۱۰) v="$(ask "IP to whitelist" "آی‌پی برای سفیدلیست" "")"; [ -n "$v" ] && cmd_ignore_ip "$v" ;;
      11 | ۱۱) cmd_update ;;
      12 | ۱۲) cmd_list ;;
      13 | ۱۳) cmd_uninstall ;;
      n | N) v="$(ask "Tunnel name" "نام تانل" "$NAME")"; valid_name "$v" && NAME="$v" || warn "bad name" "نام نامعتبر" ;;
      l | L) LANG_UI=""; choose_lang ;;
      0 | q | Q) exit 0 ;;
    esac
  done
}

usage() {
  cat <<'EOF'
bpt.sh - BackPack reverse tunnel installer / manager

Usage: ./bpt.sh [global options] <command> [options]

Global options
  --name NAME      tunnel name (default: bpt; allows several tunnels per server)
  --lang en|fa     message language
  --yes            never ask questions (use defaults / flags)
  --force          overwrite existing config / re-download the binary
  --dry-run        print what would be written/run, change nothing
  --reveal         with 'show': print the token too

Commands
  (none)                     interactive menu
  install iran               set up the ENTRY side (users connect here)
      --port 7001              tunnel (control) port the foreign server dials
      --bind 0.0.0.0           local address to bind the tunnel port to
      --ports "80,443=127.0.0.1:2096,10000-10009"   forwarded ports (BackPack syntax)
      --token TOKEN            default: random 64 hex chars
      --udp yes|no             also carry UDP (default yes)
      --transport tcp          engine transport (default tcp)
  install kharej             set up the EXIT side (abroad); dials the entry server
      --server IP[:PORT]       entry (Iran) address, default port 7001; domains work
      --token TOKEN            token printed by the Iran side
      --pool 8                 parallel connections kept ready
  status | start | stop | restart | logs
  ports [--set "LIST"]       show / change forwarded ports (Iran side)
  set-server IP[:PORT]       change the Iran address (foreign side) - e.g. after an IP change
  show [--reveal]            print the config
  list                       list tunnels created by this script
  tune                       BBR + bigger TCP buffers (run on both servers)
  ignore-ip IP               fail2ban: never ban IP (the tunnel peer)
  update                     update the BackPack binary, restart tunnels
  uninstall [--purge-binary] remove this tunnel
  help

Offline install: BPT_TARBALL=/path/backpack_linux_amd64.tar.gz or BPT_BINARY=/path/backpack
Mirror / pinned version: BP_BASE_URL=... BP_VERSION=v1.8.5
EOF
}

main() {
  local cmd="" rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) NAME="$2"; shift 2 ;;
      --lang) LANG_UI="$2"; shift 2 ;;
      --yes | -y) YES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --reveal) REVEAL=1; shift ;;
      -h | --help | help) usage; exit 0 ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else rest+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$LANG_UI" ] || { [ -n "$cmd" ] && LANG_UI=en || true; }
  valid_name "$NAME" || { echo "bad --name" >&2; exit 1; }
  case "$cmd" in
    "") choose_lang; need_root; menu ;;
    install) cmd_install "${rest[@]+"${rest[@]}"}" ;;
    status) cmd_status ;;
    start | stop | restart) cmd_service "$cmd" ;;
    logs) cmd_logs ;;
    ports) cmd_ports "${rest[@]+"${rest[@]}"}" ;;
    set-server) cmd_server "${rest[0]:-}" ;;
    show) cmd_show ;;
    list) cmd_list ;;
    tune) cmd_tune ;;
    ignore-ip) cmd_ignore_ip "${rest[0]:-}" ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall "${rest[0]:-}" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
