#!/usr/bin/env bash
# Unit tests for the helper functions in install.sh (no root, no network, nothing installed).
# Run:  bash tests/test_install.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./install.sh          # main() is guarded, only functions load
set +e                       # we assert exit codes ourselves
pass=0; fail=0
t() { local name="$1"; shift; if "$@"; then echo "PASS $name"; pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi; }
dies() { ( "$@" ) >/dev/null 2>&1; [ $? -ne 0 ]; }

# --- valid_path / render_nginx
t "valid_path accepts /api/v1/sync"   valid_path /api/v1/sync
t "valid_path rejects a space"        bash -c 'source ./install.sh; ! valid_path "/a b"'
t "valid_path rejects | and &"        bash -c 'source ./install.sh; ! valid_path "/a|b" && ! valid_path "/a&b"'
out=$(mktemp); XRAY_PATH=/x/y XRAY_LOCAL_PORT=12345 render_nginx templates/nginx-stack.conf.tpl "$out"
t "nginx: path substituted"           grep -q 'location /x/y {' "$out"
t "nginx: port substituted"           grep -q 'proxy_pass http://127.0.0.1:12345;' "$out"
t "nginx: no placeholder left"        bash -c "! grep -q '@XRAY' $out"
t "nginx: ACME location present"      grep -q 'location ^~ /.well-known/acme-challenge/' "$out"
t "nginx: 404 fallback present"       grep -q 'return 404;' "$out"
t "nginx: buffering off"              grep -q 'proxy_buffering off;' "$out"
t "render refuses a bad path"         dies bash -c "source ./install.sh; XRAY_PATH='/a|b' render_nginx templates/nginx-stack.conf.tpl /dev/null"

# --- ports
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/ss" <<'FAKE'
#!/bin/bash
# fake `ss -H -ltnp "( sport = :PORT )"` printing the real output format
port="${@: -1}"; port="${port##*:}"; port="${port%% *}"
case "$port" in
  8099) echo 'LISTEN 0      5          127.0.0.1:8099      0.0.0.0:*    users:(("python3",pid=4242,fd=3))' ;;
  80)   echo 'LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=11,fd=6),("nginx",pid=12,fd=6))' ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/ss"
export PATH="$FAKEBIN:$PATH"
srv=0
t "port_owner sees the listener"      bash -c "source ./install.sh; [[ \"\$(port_owner 8099)\" == *python3* ]]"
t "port_owner is empty on a free port" bash -c "source ./install.sh; [ -z \"\$(port_owner 8098)\" ]"
t "free port does not trip set -e"    bash -c "source ./install.sh; x=\$(port_owner 8098); echo ok >/dev/null"
t "foreign owner -> refuses"          dies bash -c "source ./install.sh; require_port_free_or_ours 8099 'nginx'"
t "nginx on :80 is ours (two worker pids)" bash -c "source ./install.sh; require_port_free_or_ours 80 nginx"
t "nginx on :80 vs allowed list without it" dies bash -c "source ./install.sh; require_port_free_or_ours 80 trusttunnel_endpoint"
t "no ss at all -> refuses (never 'free')" dies bash -c "source ./install.sh; PATH=/usr/bin:/bin; command -v ss >/dev/null && exit 0; port_owner 80"
t "our own process -> allowed"        bash -c "source ./install.sh; require_port_free_or_ours 8099 'nginx python3'"
t "free port -> allowed"              bash -c "source ./install.sh; require_port_free_or_ours 8098 'nginx'"

# --- ask
t "ask keeps a preset value"          bash -c "source ./install.sh; NONINTERACTIVE=1; V=preset; ask V 'p'; [ \"\$V\" = preset ]"
t "ask uses the default unattended"   bash -c "source ./install.sh; NONINTERACTIVE=1; unset V; ask V 'p' dflt; [ \"\$V\" = dflt ]"
t "ask dies without a default"        dies bash -c "source ./install.sh; NONINTERACTIVE=1; unset V; ask V 'p'"
t "ask_optional -> empty unattended"  bash -c "source ./install.sh; NONINTERACTIVE=1; unset O; ask_optional O 'p'; [ -z \"\$O\" ]"

# --- restore extraction
Z=$(mktemp -d)
python3 - <<PY
import zipfile, json
def mk(path, files):
    with zipfile.ZipFile(path, "w") as z:
        for n, c in files.items(): z.writestr(n, c)
mk("$Z/good.zip", {"users.json": json.dumps([{"username": "anna", "xray_uuid": "u1"}]),
                   "xray.json": json.dumps({"version": 1, "server": {"decryption": "D", "encryption": "E", "domain": "xhtt.ru", "edge_addr": "1.2.3.4"}, "clients": {"anna": {"uuid": "u1", "enabled": True}}}),
                   "tt_config.json": json.dumps({"files": {}}),
                   "messages.json": json.dumps({"welcome": "hi"}),
                   "evil.sh": "rm -rf /", "../../etc/cron.d/x": "bad"})
mk("$Z/nousers.zip", {"settings.json": "{}"})
mk("$Z/badshape.zip", {"users.json": json.dumps({"not": "a list"})})
mk("$Z/badjson.zip", {"users.json": "[", })
open("$Z/notzip.zip", "w").write("hello")
PY
t "restore: good zip extracts"        bash -c "source ./install.sh; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; ls \$RESTORE_TMP | sort | tr '\n' ' ' | grep -q '^messages.json tt_config.json users.json xray.json \$'"
t "restore: whitelist only (no evil)" bash -c "source ./install.sh; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; [ ! -e \$RESTORE_TMP/evil.sh ] && [ ! -e \$RESTORE_TMP/x ]"
t "restore: zip without users.json"   dies bash -c "source ./install.sh; RESTORE_ZIP=$Z/nousers.zip; extract_restore"
t "restore: wrong users.json shape"   dies bash -c "source ./install.sh; RESTORE_ZIP=$Z/badshape.zip; extract_restore"
t "restore: broken JSON"              dies bash -c "source ./install.sh; RESTORE_ZIP=$Z/badjson.zip; extract_restore"
t "restore: not a zip"                dies bash -c "source ./install.sh; RESTORE_ZIP=$Z/notzip.zip; extract_restore"
t "restore: missing file"             dies bash -c "source ./install.sh; RESTORE_ZIP=$Z/none.zip; extract_restore"
t "restore_value reads the domain"    bash -c "source ./install.sh; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; [ \"\$(restore_value xray.json server.domain)\" = xhtt.ru ] && [ \"\$(restore_value xray.json server.edge_addr)\" = 1.2.3.4 ]"
t "restore_value empty w/o restore"   bash -c "source ./install.sh; RESTORE_TMP=''; [ -z \"\$(restore_value xray.json server.domain)\" ]"
t "restore_value: unknown key -> empty" bash -c "source ./install.sh; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; [ -z \"\$(restore_value xray.json server.nope.deeper)\" ]"
t "restore_value: a dict is not printed" bash -c "source ./install.sh; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; [ -z \"\$(restore_value xray.json server)\" ]"

# --- restore_data (into a temp data dir, with a pre-existing file)
D=$(mktemp -d); echo '[{"username":"old"}]' > $D/users.json
bash -c "source ./install.sh; DATA_DIR=$D; RESTORE_ZIP=$Z/good.zip; extract_restore >/dev/null; restore_data >/dev/null"
t "restore_data: a file new in the panel (messages.json) comes back too" grep -q welcome $D/messages.json
t "restore_data: file replaced"       grep -q anna $D/users.json
t "restore_data: .before_restore kept" grep -q old $D/users.json.before_restore
t "restore_data: xray.json restored (key + clients)" bash -c "grep -q '\"decryption\": \"D\"' $D/xray.json && grep -q anna $D/xray.json"
t "restore_data: mode 600"            test "$(stat -c %a $D/xray.json)" = 600

# --- MAX is frozen
t "installer never asks for MAX token" bash -c "! grep -q 'ask_optional MAX_BOT_TOKEN' install.sh"
t "panel installer gets an empty MAX answer" grep -q '"\$ADMIN_ID" "\$TT_DOMAIN" "" "\${GEMINI_API_KEY' install.sh
t "panel installer feed covers all 7 prompts (+3 spare blanks)" python3 - <<'PY'
import re, sys
s = open("install.sh", encoding="utf-8").read()
m = re.search(r"printf '%s\\n' (.*?)\\\n\s*\| bash", s, re.S)
assert m, "feed not found"
args = re.findall(r'"[^"]*"', m.group(1).replace("\\\n", " "))
assert len(args) == 10, (len(args), args)
assert args[3] == '""' and "GEMINI_PROXY_URL" in args[6] and args[7:] == ['""'] * 3, args
PY
SC=$(mktemp -d); cat > $SC/systemctl <<'FAKE'
#!/bin/bash
[ "$1" = "list-unit-files" ] && { [ -n "${HAS_MAX:-}" ] && echo "trustpanel-max-bot.service enabled enabled"; exit 0; }
echo "$*" >> "$SC_LOG"
FAKE
chmod +x $SC/systemctl; export SC_LOG=$SC/log
t "freeze_max stops+disables an installed service" bash -c "source ./install.sh; PATH=$SC:\$PATH; HAS_MAX=1 freeze_max >/dev/null; grep -q 'disable --now trustpanel-max-bot.service' $SC/log"
: > $SC/log
t "freeze_max does nothing when not installed"     bash -c "source ./install.sh; PATH=$SC:\$PATH; freeze_max >/dev/null; [ ! -s $SC/log ]"

# --- env_value
P=$(mktemp -d); printf 'BOT_TOKEN=123:abc\nTRUSTTUNNEL_DOMAIN=vpn.example.test\n' > $P/.env
t "env_value reads .env"              bash -c "source ./install.sh; PANEL_DIR=$P; [ \"\$(env_value TRUSTTUNNEL_DOMAIN)\" = vpn.example.test ]"
t "env_value empty for missing key"   bash -c "source ./install.sh; PANEL_DIR=$P; [ -z \"\$(env_value NOPE)\" ]"
t "env_value empty w/o .env"          bash -c "source ./install.sh; PANEL_DIR=/nonexistent; [ -z \"\$(env_value BOT_TOKEN)\" ]"

echo; echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
