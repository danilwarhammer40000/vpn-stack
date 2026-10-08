#!/usr/bin/env python3
"""
Xray server identity + base config for vpn-stack. Standard library only.

  xray_setup.py identity --domain D --edge-addr IP --out FILE [--mlkem] [--force]
      Runs `xray vlessenc` and stores the key pair plus the public link parameters
      in the "server" section of FILE (the panel's data/xray.json, mode 600). The
      "clients" section is never touched. NEVER replaces an existing server section
      unless --force: a new key pair silently breaks every client link ever issued.

  xray_setup.py config --identity FILE --out CONFIG [--port 10085]
      Writes a base Xray config (no clients; the panel fills them in) whose
      decryption key, path and padding come from FILE's "server" section.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

DEFAULTS = {"port": 443, "path": "/api/v1/sync", "padding_key": "pref", "padding_placement": "cookie"}


def write_atomic(path: str, data: dict, mode: int) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def parse_vlessenc(text: str, want_mlkem: bool) -> dict:
    """The tool prints an X25519 block, then an ML-KEM-768 block, each with
    a "decryption" and an "encryption" line. Pick one block by its header."""
    section, found = None, {"x25519": {}, "mlkem": {}}
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Authentication:"):
            section = "mlkem" if "ML-KEM" in line else "x25519"
        elif section and line.startswith('"decryption"'):
            found[section]["decryption"] = line.split('"')[3]
        elif section and line.startswith('"encryption"'):
            found[section]["encryption"] = line.split('"')[3]

    pair = found["mlkem" if want_mlkem else "x25519"]
    if not pair.get("decryption") or not pair.get("encryption"):
        raise SystemExit("could not parse `xray vlessenc` output (xray too old?)")
    return pair


def load_store(path: str) -> dict:
    if not os.path.exists(path):
        return {"version": 1, "server": {}, "clients": {}}
    try:
        data = json.load(open(path))
    except json.JSONDecodeError as e:
        raise SystemExit(f"{path} is not valid JSON ({e}); refusing to overwrite it")
    if not isinstance(data, dict):
        raise SystemExit(f"{path} has an unexpected shape; refusing to overwrite it")
    data.setdefault("version", 1)
    data.setdefault("server", {})
    data.setdefault("clients", {})
    return data


def cmd_identity(a) -> None:
    store = load_store(a.out)
    if store["server"].get("decryption") and not a.force:
        print(f"server identity already present in {a.out}, keeping it (use --force to replace)")
        return

    out = subprocess.run([a.xray_bin, "vlessenc"], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"`xray vlessenc` failed: {out.stderr.strip()[-300:]}")

    pair = parse_vlessenc(out.stdout, a.mlkem)
    store["server"] = {
        **pair,
        "domain": a.domain,
        "edge_addr": a.edge_addr or a.domain,
        "port": DEFAULTS["port"],
        "path": a.path,
        "padding_key": DEFAULTS["padding_key"],
        "padding_placement": DEFAULTS["padding_placement"],
    }
    write_atomic(a.out, store, 0o600)
    print(f"server identity written to {a.out} (key pair: {'ML-KEM-768' if a.mlkem else 'X25519'})")


def cmd_config(a) -> None:
    ident = load_store(a.identity)["server"]
    if not ident.get("decryption"):
        raise SystemExit(f"{a.identity} has no server identity yet (run `identity` first)")
    s = {**DEFAULTS, **ident}
    cfg = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "127.0.0.1",
            "port": a.port,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": ident["decryption"]},
            "streamSettings": {
                "network": "xhttp",
                "security": "none",
                "xhttpSettings": {
                    "path": s["path"],
                    "mode": "packet-up",
                    "xPaddingObfsMode": True,
                    "xPaddingKey": s["padding_key"],
                    "xPaddingPlacement": s["padding_placement"],
                },
            },
        }],
        "outbounds": [{"protocol": "freedom"}],
    }
    # Xray runs as "nobody": the config must be world-readable.
    write_atomic(a.out, cfg, 0o644)
    print(f"base config written to {a.out}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--xray-bin", default="/usr/local/bin/xray")
    sub = p.add_subparsers(dest="cmd", required=True)

    i = sub.add_parser("identity")
    i.add_argument("--domain", required=True)
    i.add_argument("--edge-addr", default="")
    i.add_argument("--path", default=DEFAULTS["path"])
    i.add_argument("--out", required=True)
    i.add_argument("--mlkem", action="store_true")
    i.add_argument("--force", action="store_true")
    i.set_defaults(fn=cmd_identity)

    c = sub.add_parser("config")
    c.add_argument("--identity", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--port", type=int, default=10085)
    c.set_defaults(fn=cmd_config)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
