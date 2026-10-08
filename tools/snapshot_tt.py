#!/usr/bin/env python3
"""
Snapshot / restore of the TrustTunnel endpoint configuration as ONE JSON file
(tt_config.json). JSON, because the panel's backup + "📥 Загрузить БД" restore
only handle JSON files. The snapshot rides along in every backup, so a reinstall
can bring the TrustTunnel setup back without re-running the wizard.

  snapshot_tt.py save    [--tt-dir /opt/trusttunnel] [--out /opt/trustpanel/data/tt_config.json]
  snapshot_tt.py restore [--tt-dir /opt/trusttunnel] [--src  /opt/trustpanel/data/tt_config.json] [--force]

Only the small config files are stored (vpn.toml, hosts.toml, rules.toml). Certificates
are NOT: hosts.toml points at the certbot paths, and the new server gets a fresh
certificate for the same domain. credentials.toml is derived from the panel DB.
"""
import argparse
import json
import os
import sys
import tempfile
import time

FILES = ("vpn.toml", "hosts.toml", "rules.toml")


def cmd_save(a) -> int:
    files = {}
    for name in FILES:
        path = os.path.join(a.tt_dir, name)
        if os.path.isfile(path):
            files[name] = open(path, encoding="utf-8").read()

    if "vpn.toml" not in files or "hosts.toml" not in files:
        print(f"snapshot skipped: vpn.toml / hosts.toml not found in {a.tt_dir}", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(a.out))
    with os.fdopen(fd, "w") as f:
        json.dump({"saved_at": int(time.time()), "files": files}, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, a.out)
    print(f"snapshot saved: {', '.join(files)} -> {a.out}")
    return 0


def cmd_restore(a) -> int:
    data = json.load(open(a.src, encoding="utf-8"))
    files = data.get("files", {})
    if "vpn.toml" not in files or "hosts.toml" not in files:
        print("snapshot is incomplete (vpn.toml / hosts.toml missing)", file=sys.stderr)
        return 1

    os.makedirs(a.tt_dir, exist_ok=True)
    for name, content in files.items():
        if name not in FILES:
            continue  # never write anything outside the known file names
        path = os.path.join(a.tt_dir, name)
        if os.path.exists(path) and not a.force:
            print(f"{path} exists, keeping it (use --force to overwrite)")
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(path, 0o640)
        print(f"restored {path}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--tt-dir", default=os.getenv("TT_DIR", "/opt/trusttunnel"))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("save")
    s.add_argument("--out", default="/opt/trustpanel/data/tt_config.json")
    s.set_defaults(fn=cmd_save)

    r = sub.add_parser("restore")
    r.add_argument("--src", default="/opt/trustpanel/data/tt_config.json")
    r.add_argument("--force", action="store_true")
    r.set_defaults(fn=cmd_restore)

    a = p.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
