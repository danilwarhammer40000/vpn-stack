#!/usr/bin/env bash
# vpn-stack installer: nginx :80 + TrustTunnel :443 + Xray (VLESS/XHTTP behind a CDN)
# + TrustPanel (Telegram bot) managing both VPNs. Ubuntu 24.04, run as root.
#
#   sudo ./install.sh                          fresh install (asks for what it needs)
#   sudo ./install.sh --restore backup.zip     fresh server + the zip the bot sent you
#   sudo ./install.sh --answers stack.env      non-interactive (see stack.env.example)
#   sudo ./install.sh --check                  only print the health summary
#   add --firewall to also configure ufw (SSH, 80/tcp, 443/tcp+udp)
#
# Safe to re-run: every step checks what already exists and skips it.
set -euo pipefail

STACK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_HOME="${STACK_HOME:-/opt/vpn-stack}"
PANEL_DIR="${PANEL_DIR:-/opt/trustpanel}"
DATA_DIR="${DATA_DIR:-$PANEL_DIR/data}"
TT_DIR="${TT_DIR:-/opt/trusttunnel}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
XRAY_LOCAL_PORT="${XRAY_LOCAL_PORT:-10085}"
XRAY_PATH="${XRAY_PATH:-/api/v1/sync}"
XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"   # first version we verified; older ones lack xPaddingObfsMode
TT_VERSION="${TT_VERSION:-}"               # empty = latest release
PANEL_REPO="${PANEL_REPO:-https://github.com/danilwarhammer40000/tg-trust.git}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/vpn-stack.conf}"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/certbot}"

RESTORE_ZIP=""
ANSWERS_FILE=""
WITH_FIREWALL=0
CHECK_ONLY=0
NONINTERACTIVE=0
RESTORE_TMP=""

# A restore brings back every flat *.json from the zip (the panel's backup is exactly its
# database files, and newer panel versions add some, e.g. messages.json). Anything else,
# and anything with a path in its name, is ignored.

# ------------------------------------------------------------------ helpers

if [ -t 1 ]; then C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_OK=""; C_WARN=""; C_ERR=""; C_B=""; C_0=""; fi

step() { echo; echo "${C_B}==> $*${C_0}"; }
info() { echo "    $*"; }
ok()   { echo "    ${C_OK}✔${C_0} $*"; }
warn() { echo "    ${C_WARN}!${C_0} $*" >&2; }
die()  { echo "${C_ERR}ERROR:${C_0} $*" >&2; exit 1; }

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ask VAR "prompt" [default] [secret]  -- keeps a value already set in the environment
ask() {
    local var="$1" prompt="$2" default="${3:-}" secret="${4:-}" reply=""
    if [ -n "${!var:-}" ]; then return 0; fi
    if [ "$NONINTERACTIVE" = 1 ] || [ ! -t 0 ]; then
        if [ -n "$default" ]; then printf -v "$var" '%s' "$default"; return 0; fi
        die "$var is required (set it in the answers file)"
    fi
    if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
    if [ "$secret" = secret ]; then read -r -s -p "$prompt: " reply; echo
    else read -r -p "$prompt: " reply; fi
    reply="${reply//$'\r'/}"
    printf -v "$var" '%s' "${reply:-$default}"
}

ask_optional() {
    local var="$1" prompt="$2"
    if [ -n "${!var+set}" ]; then return 0; fi
    if [ "$NONINTERACTIVE" = 1 ] || [ ! -t 0 ]; then printf -v "$var" '%s' ""; return 0; fi
    local reply; read -r -p "$prompt (Enter to skip): " reply
    printf -v "$var" '%s' "${reply//$'\r'/}"
}

valid_path() { [[ "$1" =~ ^/[A-Za-z0-9/_.-]+$ ]]; }

render_nginx() {  # render_nginx TEMPLATE OUT
    valid_path "$XRAY_PATH" || die "XRAY_PATH '$XRAY_PATH' has characters that are not allowed"
    sed -e "s|@XRAY_PATH@|$XRAY_PATH|g" -e "s|@XRAY_PORT@|$XRAY_LOCAL_PORT|g" "$1" > "$2"
}

# port_owner PORT -> process names listening on that TCP port (empty if free)
port_owner() {
    command -v ss >/dev/null || die "ss (package iproute2) is required to check the ports"
    { ss -H -ltnp "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | sed 's/users:(("//; s/"$//' | sort -u | tr '\n' ' '; } || true
}

require_port_free_or_ours() {  # PORT "allowed names..."
    local port="$1" allowed="$2" owner name
    owner="$(port_owner "$port")"
    for name in $owner; do
        case " $allowed " in *" $name "*) ;; *)
            die "port $port is already used by '$name'. Stop or remove it first (e.g. an older tunnel service), then re-run." ;;
        esac
    done
}

# ------------------------------------------------------------------ steps

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --restore)  RESTORE_ZIP="${2:?--restore needs a file}"; shift 2 ;;
            --answers)  ANSWERS_FILE="${2:?--answers needs a file}"; shift 2 ;;
            --firewall) WITH_FIREWALL=1; shift ;;
            --check)    CHECK_ONLY=1; shift ;;
            --yes|-y)   NONINTERACTIVE=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
}

load_answers() {
    if [ -n "$ANSWERS_FILE" ]; then
        [ -f "$ANSWERS_FILE" ] || die "answers file not found: $ANSWERS_FILE"
        set -a; . "$ANSWERS_FILE"; set +a
        NONINTERACTIVE=1
    fi
}

extract_restore() {
    [ -n "$RESTORE_ZIP" ] || return 0
    [ -f "$RESTORE_ZIP" ] || die "restore file not found: $RESTORE_ZIP"
    RESTORE_TMP="$(mktemp -d)"
    chmod 700 "$RESTORE_TMP"
    python3 - "$RESTORE_ZIP" "$RESTORE_TMP" <<'PY'
import json, re, sys, zipfile
src, dst = sys.argv[1:]
try:
    zf = zipfile.ZipFile(src)
except zipfile.BadZipFile:
    sys.exit("not a valid zip file")
found = sorted({n for n in zf.namelist() if re.fullmatch(r"[A-Za-z0-9_.-]+\.json", n)})
if "users.json" not in found:
    sys.exit("the archive has no users.json, refusing to restore from it")
for n in found:
    data = zf.read(n)
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError:
        sys.exit(f"{n} in the archive is not valid JSON")
    if n == "users.json" and not (isinstance(parsed, list) and all(isinstance(u, dict) and u.get("username") for u in parsed)):
        sys.exit("users.json in the archive has an unexpected shape")
    open(f"{dst}/{n}", "wb").write(data)
print("restore files:", ", ".join(found))
PY
}

restore_value() {  # restore_value FILE DOTTED.KEY -> value from a JSON file in the restore dir
    [ -n "$RESTORE_TMP" ] && [ -f "$RESTORE_TMP/$1" ] || return 0
    python3 - "$RESTORE_TMP/$1" "$2" 2>/dev/null <<'PY' || true
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node.get(part, "") if isinstance(node, dict) else ""
print(node if isinstance(node, (str, int)) else "")
PY
}

env_value() {  # env_value KEY -> value from the panel's .env (empty if none)
    [ -f "$PANEL_DIR/.env" ] || return 0
    grep -m1 "^$1=" "$PANEL_DIR/.env" | cut -d= -f2- || true
}

collect_config() {
    step "Configuration"
    BOT_TOKEN="${BOT_TOKEN:-$(env_value BOT_TOKEN)}"
    ADMIN_ID="${ADMIN_ID:-$(env_value ADMIN_ID)}"
    TT_DOMAIN="${TT_DOMAIN:-$(env_value TRUSTTUNNEL_DOMAIN)}"
    ask BOT_TOKEN "Telegram BOT_TOKEN" "" secret
    ask ADMIN_ID "Telegram ADMIN_ID (numeric)"
    ask TT_DOMAIN "TrustTunnel domain (A record -> this server, NOT behind the CDN)"
    ask XRAY_DOMAIN "Xray domain (behind the CDN)" "$(restore_value xray.json server.domain)"
    ask XRAY_EDGE_ADDR "CDN edge IP that clients connect to" "$(restore_value xray.json server.edge_addr)"
    ask_optional ACME_EMAIL "E-mail for Let's Encrypt expiry notices"
    ask_optional GEMINI_API_KEY "GEMINI_API_KEY (AI auto-renewal)"
    ask_optional LOG_CHANNEL_ID "LOG_CHANNEL_ID"
    ask_optional GEMINI_PROXY_URL "GEMINI_PROXY_URL (only if Gemini is blocked from this server)"

    [[ "$ADMIN_ID" =~ ^[0-9]+$ ]] || die "ADMIN_ID must be a number"
    [[ "$TT_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "TT_DOMAIN looks invalid"
    [[ "$XRAY_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "XRAY_DOMAIN looks invalid"
    [[ "$XRAY_EDGE_ADDR" =~ ^[A-Za-z0-9.:-]+$ ]] || die "XRAY_EDGE_ADDR looks invalid"
    [ "$TT_DOMAIN" != "$XRAY_DOMAIN" ] || die "TT_DOMAIN and XRAY_DOMAIN must differ: one goes straight to this server, the other through the CDN"
    valid_path "$XRAY_PATH" || die "XRAY_PATH is invalid"
}

preflight() {
    step "Preflight"
    [ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh)"
    if ! grep -qs 'VERSION_ID="24.04"' /etc/os-release; then
        warn "this installer was written for Ubuntu 24.04; continuing anyway"
    fi
    command -v systemctl >/dev/null || die "systemd is required"

    require_port_free_or_ours 80  "nginx"
    require_port_free_or_ours 443 "trusttunnel_endpoint nginx"
    ok "ports 80 and 443 are free (or already ours)"

    local resolved public
    resolved="$(getent ahostsv4 "$TT_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    public="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
        warn "$TT_DOMAIN does not resolve yet: Let's Encrypt will fail until its A record points here"
    elif [ -n "$public" ] && [ "$resolved" != "$public" ]; then
        warn "$TT_DOMAIN resolves to $resolved but this server is $public: Let's Encrypt will fail until they match"
    else
        ok "$TT_DOMAIN -> $resolved"
    fi
}

install_packages() {
    step "System packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx certbot python3 python3-venv python3-pip git curl unzip ca-certificates binutils
    ok "installed"
}

setup_nginx() {
    step "nginx on :80 (ACME challenges + Xray path + 404)"
    mkdir -p "$ACME_WEBROOT"
    rm -f /etc/nginx/sites-enabled/default
    render_nginx "$STACK_SRC/templates/nginx-stack.conf.tpl" "$NGINX_CONF"
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    ok "nginx running with $NGINX_CONF"
}

issue_certificate() {
    step "Let's Encrypt certificate for $TT_DOMAIN"
    local live="/etc/letsencrypt/live/$TT_DOMAIN"
    if [ -d "$live" ]; then
        ok "certificate already present"
    else
        local mail_args=(--register-unsafely-without-email)
        [ -n "${ACME_EMAIL:-}" ] && mail_args=(-m "$ACME_EMAIL")
        certbot certonly --webroot -w "$ACME_WEBROOT" -d "$TT_DOMAIN" \
            --non-interactive --agree-tos "${mail_args[@]}" \
            || die "certbot failed. Check that $TT_DOMAIN points to this server and port 80 is reachable from the internet."
        ok "certificate issued"
    fi

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/vpn-stack-trusttunnel.sh <<'HOOK'
#!/bin/sh
# TrustTunnel only reads the certificate at start: restart it after a renewal.
systemctl restart trusttunnel 2>/dev/null || true
HOOK
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vpn-stack-trusttunnel.sh
    systemctl enable --now certbot.timer 2>/dev/null || warn "certbot.timer not found: add a cron job for 'certbot renew'"

    if certbot renew --dry-run >/dev/null 2>&1; then ok "renewal dry-run passed (nginx serves the challenge)"
    else warn "renewal dry-run failed: check 'certbot renew --dry-run' output before the first renewal is due"; fi
}

install_trusttunnel() {
    step "TrustTunnel endpoint (:443)"
    if [ -x "$TT_DIR/trusttunnel_endpoint" ]; then
        ok "already installed in $TT_DIR"
    else
        local args=()
        [ -n "$TT_VERSION" ] && args=(-V "$TT_VERSION")
        curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh \
            | sh -s - "${args[@]}"
        [ -x "$TT_DIR/trusttunnel_endpoint" ] || die "TrustTunnel install did not produce $TT_DIR/trusttunnel_endpoint"
        ok "installed"
    fi

    if [ -f "$TT_DIR/vpn.toml" ] && [ -f "$TT_DIR/hosts.toml" ]; then
        ok "vpn.toml / hosts.toml already present"
    elif [ -n "$RESTORE_TMP" ] && [ -f "$RESTORE_TMP/tt_config.json" ]; then
        python3 "$STACK_SRC/tools/snapshot_tt.py" --tt-dir "$TT_DIR" restore --src "$RESTORE_TMP/tt_config.json"
        ok "TrustTunnel config restored from the backup, wizard skipped"
    else
        cat <<EOF

    The TrustTunnel setup wizard starts now. Answer like this:
      - address to listen on:       0.0.0.0:443
      - username / password:        any temporary user (the panel rewrites credentials.toml from its database)
      - certificate:                "Provide path to existing certificate", then enter
        /etc/letsencrypt/live/$TT_DOMAIN/fullchain.pem /etc/letsencrypt/live/$TT_DOMAIN/privkey.pem
      - everything else:            keep the defaults (files are created in $TT_DIR)

EOF
        ( cd "$TT_DIR" && ./setup_wizard )
    fi

    [ -f "$TT_DIR/vpn.toml" ] && [ -f "$TT_DIR/hosts.toml" ] \
        || die "vpn.toml / hosts.toml are missing in $TT_DIR: the wizard did not finish"
    grep -q "$TT_DOMAIN" "$TT_DIR/hosts.toml" || warn "hosts.toml does not mention $TT_DOMAIN: check the hostname the wizard saved"

    if [ ! -f /etc/systemd/system/trusttunnel.service ]; then
        [ -f "$TT_DIR/trusttunnel.service.template" ] || die "trusttunnel.service.template not found in $TT_DIR"
        cp "$TT_DIR/trusttunnel.service.template" /etc/systemd/system/trusttunnel.service
    fi
    systemctl daemon-reload
    systemctl enable trusttunnel   # started by the panel's first sync, once credentials.toml is written
}

install_panel() {
    step "TrustPanel (Telegram bot)"
    if [ -f "$PANEL_DIR/.env" ]; then
        ok "already installed in $PANEL_DIR"
    else
        if [ ! -d "$PANEL_DIR/.git" ]; then
            if [ -e "$PANEL_DIR" ] && [ -n "$(ls -A "$PANEL_DIR" 2>/dev/null)" ]; then
                die "$PANEL_DIR exists, is not empty and is not a git checkout: move it away first"
            fi
            git clone "$PANEL_REPO" "$PANEL_DIR"
        fi
        # The panel's own installer asks its questions on stdin, in this order:
        #   BOT_TOKEN, ADMIN_ID, TRUSTTUNNEL_DOMAIN, MAX_BOT_TOKEN, GEMINI_API_KEY,
        #   LOG_CHANNEL_ID, GEMINI_PROXY_URL
        # The 4th is the MAX bot token: that part is frozen, so it always gets an empty answer.
        # Three spare blank answers follow, so an extra OPTIONAL question added upstream later
        # reads "skip" instead of hitting end-of-input (which would abort the whole install).
        printf '%s\n' "$BOT_TOKEN" "$ADMIN_ID" "$TT_DOMAIN" "" "${GEMINI_API_KEY:-}" "${LOG_CHANNEL_ID:-}" \
            "${GEMINI_PROXY_URL:-}" "" "" "" \
            | bash "$PANEL_DIR/install.sh"
        grep -q "^BOT_TOKEN=${BOT_TOKEN}$" "$PANEL_DIR/.env" && grep -q "^TRUSTTUNNEL_DOMAIN=${TT_DOMAIN}$" "$PANEL_DIR/.env" \
            || die "the panel's .env does not contain the answers just given: its installer prompts have probably changed. Check $PANEL_DIR/.env"
        ok "panel installed"
    fi
    mkdir -p "$DATA_DIR"; chmod 700 "$DATA_DIR"
}

freeze_max() {
    step "MAX bot (frozen)"
    if systemctl list-unit-files trustpanel-max-bot.service 2>/dev/null | grep -q trustpanel-max-bot; then
        systemctl disable --now trustpanel-max-bot.service >/dev/null 2>&1 || true
        ok "trustpanel-max-bot.service stopped and disabled (code stays in the repo)"
    else
        ok "not installed, nothing to do"
    fi
}

apply_overlay() {
    step "Xray (admin-only), manual tariffs and backup files in the panel"
    # Edits the panel's files with exact-match replacements and adds the new modules.
    # Files the panel repo already has (e.g. after you committed the overlay) are kept.
    ( cd "$PANEL_DIR" && python3 "$STACK_SRC/overlay/apply_xray_patch.py" ) \
        || die "the panel's files differ from what the patch expects (see the list above). The panel still works, just without Xray. Send me that list."
    ok "panel patched"
}

restore_data() {
    [ -n "$RESTORE_TMP" ] || return 0
    step "Restoring the database from $RESTORE_ZIP"
    local path f
    for path in "$RESTORE_TMP"/*.json; do
        [ -f "$path" ] || continue
        f="$(basename "$path")"
        [ -f "$DATA_DIR/$f" ] && cp "$DATA_DIR/$f" "$DATA_DIR/$f.before_restore"
        install -m 600 "$path" "$DATA_DIR/$f"
        ok "restored $f"
    done
}

install_xray() {
    step "Xray $XRAY_VERSION"
    if xray version 2>/dev/null | head -1 | grep -q "${XRAY_VERSION#v}"; then
        ok "already installed"
    else
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"
    fi
    [ "$(strings /usr/local/bin/xray | grep -c xPaddingObfsMode)" -gt 0 ] \
        || die "this Xray build has no xPaddingObfsMode: the CDN blocks default padding, so it needs $XRAY_VERSION or newer"

    python3 "$STACK_SRC/tools/xray_setup.py" identity \
        --domain "$XRAY_DOMAIN" --edge-addr "$XRAY_EDGE_ADDR" --path "$XRAY_PATH" --out "$DATA_DIR/xray.json"

    if grep -q '"protocol": *"vless"' "$XRAY_CONF" 2>/dev/null; then
        ok "keeping the existing Xray config (the panel manages its clients)"
    else
        python3 "$STACK_SRC/tools/xray_setup.py" config --identity "$DATA_DIR/xray.json" \
            --out "$XRAY_CONF" --port "$XRAY_LOCAL_PORT"
    fi
    xray run -test -config "$XRAY_CONF" >/dev/null || die "xray rejected $XRAY_CONF"
    systemctl enable xray
}

first_sync() {
    step "First synchronisation (TrustTunnel credentials + Xray clients)"
    install -d "$STACK_HOME/tools"
    install -m 755 "$STACK_SRC"/tools/*.py "$STACK_HOME/tools/"

    python3 "$STACK_HOME/tools/snapshot_tt.py" --tt-dir "$TT_DIR" save --out "$DATA_DIR/tt_config.json" \
        || warn "could not snapshot the TrustTunnel config"

    # Every scheduled backup refreshes the snapshot first, so it is never stale.
    mkdir -p /etc/systemd/system/trustpanel-backup.service.d
    cat > /etc/systemd/system/trustpanel-backup.service.d/vpn-stack.conf <<EOF
[Service]
ExecStartPre=-/usr/bin/python3 $STACK_HOME/tools/snapshot_tt.py --tt-dir $TT_DIR save --out $DATA_DIR/tt_config.json
EOF
    systemctl daemon-reload

    if ( cd "$PANEL_DIR" && set -a && . ./.env && set +a \
         && ./venv/bin/python -c "from core.service import full_resync_and_reload as f; f()" ); then
        ok "synchronised"
    else
        warn "first sync failed. Fix the cause (see above / journalctl), then press «🔄 Sync users» in the bot."
    fi
    systemctl restart trustpanel-bot
}

setup_firewall() {
    [ "$WITH_FIREWALL" = 1 ] || return 0
    step "Firewall (ufw)"
    command -v ufw >/dev/null || apt-get install -y ufw
    local ssh_port
    ssh_port="$(ss -H -ltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]; exit}')"
    ssh_port="${ssh_port:-22}"
    ufw allow "$ssh_port/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp   # QUIC for TrustTunnel
    ufw --force enable
    ok "ufw enabled (ssh $ssh_port, 80/tcp, 443/tcp+udp)"
    info "port 80 is open to everyone because Let's Encrypt needs it; the Xray path is protected by the VLESS keys"
}

health_summary() {
    step "Status"
    local svc code
    for svc in nginx trusttunnel xray trustpanel-bot; do
        if systemctl is-active --quiet "$svc"; then ok "$svc is running"; else warn "$svc is NOT running (journalctl -u $svc -n 30)"; fi
    done

    info "listening: :80=$(port_owner 80) :443=$(port_owner 443) :$XRAY_LOCAL_PORT=$(port_owner "$XRAY_LOCAL_PORT")"

    code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
    [ "$code" = 404 ] && ok "http://127.0.0.1/ -> 404 (expected)" || warn "http://127.0.0.1/ -> $code (expected 404)"
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1$XRAY_PATH/probe" || true)"
    case "$code" in 400|404) ok "$XRAY_PATH reaches Xray ($code without a session is normal)" ;; *) warn "$XRAY_PATH -> $code (expected 400)";; esac
}

final_notes() {
    cat <<EOF

${C_B}Done.${C_0}
  1. Open your bot in Telegram and add a user (TrustTunnel link as before).
     Xray is admin-only and opt-in: open a user's card -> "🛰 Xray" -> turn it on to get a link.
  2. Point the CDN origin of $XRAY_DOMAIN at this server, HTTP port 80, cache off.
  3. Backups: the bot sends a zip daily. Keep it somewhere safe, it contains your Xray private key and
     user passwords. To rebuild a server: ./install.sh --restore <that zip>
EOF
}

main() {
    parse_args "$@"
    load_answers

    if [ "$CHECK_ONLY" = 1 ]; then
        XRAY_DOMAIN="${XRAY_DOMAIN:-}"; health_summary; exit 0
    fi

    [ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh)"
    command -v python3 >/dev/null || { apt-get update -y && apt-get install -y python3; }

    trap '[ -z "$RESTORE_TMP" ] || rm -rf "$RESTORE_TMP"' EXIT
    extract_restore

    collect_config
    preflight
    install_packages
    setup_nginx
    issue_certificate
    install_trusttunnel
    install_panel
    freeze_max
    apply_overlay
    restore_data
    install_xray
    first_sync
    setup_firewall
    health_summary
    final_notes
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
