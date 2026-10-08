#!/usr/bin/env python3
"""
Adds admin-only Xray control, manual per-client tariffs and the Xray backup
files to an existing TrustPanel checkout.

Run from the repository root of the panel:

    python3 /path/to/overlay/apply_xray_patch.py --check   # dry run
    python3 /path/to/overlay/apply_xray_patch.py           # applies

What it does:
  * edits existing files with EXACT-MATCH replacements (core/paths.py,
    core/service.py, core/payment.py, bot/bot.py, bot/handlers/list_users.py);
  * copies the new files from overlay/ (core/xray.py, core/tariff.py,
    bot/handlers/admin_xray.py, bot/handlers/admin_tariff.py, tests) but never
    overwrites a file that already exists in the panel.

If any snippet is not found exactly once (the file changed since this patch was
written) NOTHING is written and the problems are listed, so you never end up
half-patched. Safe to run twice: already-patched files are skipped.
"""
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

NEW_FILES = [
    "core/xray.py",
    "core/tariff.py",
    "bot/handlers/admin_xray.py",
    "bot/handlers/admin_tariff.py",
    "tests/test_xray.py",
    "tests/test_tariff.py",
]

EDITS = {
    # ---- Xray data + backup: the separate xray.json and the TrustTunnel snapshot
    "core/paths.py": [
        (
            'AUTO_RENEWAL_SETTINGS_PATH = os.path.join(DATA_DIR, "auto_renewal_settings.json")\n',
            'AUTO_RENEWAL_SETTINGS_PATH = os.path.join(DATA_DIR, "auto_renewal_settings.json")\n'
            '# Xray lives in its own file (server key + per-user clients), and a snapshot of\n'
            '# the TrustTunnel config rides along: both must survive a server reinstall.\n'
            'XRAY_STORE_PATH = os.path.join(DATA_DIR, "xray.json")\n'
            'STACK_SNAPSHOT_PATH = os.path.join(DATA_DIR, "tt_config.json")\n',
        ),
        (
            # Anchored on the first entry only, so other entries (messages.json, ...) may come and go.
            'BACKUP_FILES = {\n    "users.json": DB_PATH,\n',
            'BACKUP_FILES = {\n    "users.json": DB_PATH,\n'
            '    "xray.json": XRAY_STORE_PATH,\n'
            '    "tt_config.json": STACK_SNAPSHOT_PATH,\n',
        ),
    ],
    # ---- every add/extend/delete/sync/cleanup goes through this function
    "core/service.py": [
        (
            "def full_resync_and_reload() -> None:\n"
            "    users = list_users()\n"
            "    rebuild_credentials_from_db(users)\n"
            "    restart_trusttunnel()\n",
            "def full_resync_and_reload() -> None:\n"
            "    users = list_users()\n"
            "    rebuild_credentials_from_db(users)\n"
            "    restart_trusttunnel()\n"
            "\n"
            "    # Xray (admin-only, opt-in per user): a no-op unless data/xray.json exists.\n"
            "    # Imported lazily so Xray problems can never break module import.\n"
            "    from core.xray import sync_xray_from_users\n"
            "    sync_xray_from_users()\n",
        ),
    ],
    # ---- manual tariff: a pinned price replaces the automatic one
    "core/payment.py": [
        (
            "def calc_monthly_price(username: str):\n",
            "def calc_monthly_price(username: str, ignore_custom: bool = False):\n",
        ),
        (
            "    user = get_user(username) or {}\n"
            "    followers = get_followers(username)\n",
            "    user = get_user(username) or {}\n"
            "\n"
            "    # Manual per-client tariff set by the admin (core/tariff.py) replaces the\n"
            "    # automatic price entirely, the extra-link surcharge included.\n"
            "    custom = user.get(\"custom_rate\")\n"
            "    if custom and not ignore_custom:\n"
            "        return int(custom), 0\n"
            "\n"
            "    followers = get_followers(username)\n",
        ),
    ],
    "bot/bot.py": [
        (
            "    add_user,\n    auto_renewal_review,\n",
            "    add_user,\n    admin_tariff,\n    admin_xray,\n    auto_renewal_review,\n",
        ),
        (
            "    mass_delete.router,\n    get_link.router,\n):",
            "    mass_delete.router,\n    get_link.router,\n    admin_tariff.router,\n    admin_xray.router,\n):",
        ),
    ],
    # ---- the admin's user card: two new buttons, and the Xray link next to "Get link"
    "bot/handlers/list_users.py": [
        (
            "from core.generator import generate_link\n\nrouter = Router()",
            "from core.generator import generate_link\nfrom core.xray import xray_block\n\nrouter = Router()",
        ),
        (
            # End of the base button list, right before the optional "invite link" row.
            "    ]\n\n    if not tg_id:\n",
            "    ]\n"
            "\n"
            "    # Admin-only: Xray and the manual tariff (a follower's tariff is its leader's).\n"
            '    rows.append([InlineKeyboardButton(text="🛰 Xray", callback_data=f"act_xray:{username}")])\n'
            "    if not linked_to:\n"
            '        rows.append([InlineKeyboardButton(text="💰 Тариф", callback_data=f"act_tariff:{username}")])\n'
            "\n"
            "    if not tg_id:\n",
        ),
        (
            "    link = generate_link(username, DOMAIN)\n"
            "\n"
            "    await call.message.answer(\n"
            '        format_full_instructions_message(username, user.get("password"), user.get("expires_at"), link)\n'
            "    )\n"
            "    await call.answer()",
            "    link = generate_link(username, DOMAIN)\n"
            "\n"
            "    await call.message.answer(\n"
            '        format_full_instructions_message(username, user.get("password"), user.get("expires_at"), link)\n'
            "    )\n"
            "\n"
            "    block = xray_block(user)\n"
            "    if block:\n"
            '        await call.message.answer(block, parse_mode="HTML")\n'
            "\n"
            "    await call.answer()",
        ),
    ],
}

MARKERS = {
    "core/paths.py": "XRAY_STORE_PATH",
    "core/service.py": "core.xray",
    "core/payment.py": "custom_rate",
    "bot/bot.py": "admin_tariff",
    "bot/handlers/list_users.py": "act_xray",
}


def main() -> int:
    dry = "--check" in sys.argv
    root = Path.cwd()
    problems, results, copies = [], {}, []

    for rel, edits in EDITS.items():
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel}: file not found (run from the repo root)")
            continue

        text = path.read_text(encoding="utf-8")

        if MARKERS[rel] in text:
            print(f"= {rel}: already patched, skipping")
            continue

        for i, (old, new) in enumerate(edits, 1):
            n = text.count(old)
            if n != 1:
                problems.append(f"{rel}: edit #{i} matched {n} times (expected exactly 1)")
                continue
            text = text.replace(old, new, 1)

        results[path] = text

    for rel in NEW_FILES:
        src, dst = HERE / rel, root / rel
        if not src.is_file():
            problems.append(f"overlay file missing: {rel}")
        elif dst.exists():
            print(f"= {rel}: exists in the panel, kept")
        else:
            copies.append((src, dst, rel))

    if problems:
        print("NOTHING WRITTEN. Problems:")
        for p in problems:
            print("  -", p)
        return 1

    verb = "would patch" if dry else "patched"
    for path, text in results.items():
        print(f"{verb} {path.relative_to(root)}")
        if not dry:
            path.write_text(text, encoding="utf-8")

    for src, dst, rel in copies:
        print(("would add " if dry else "added ") + rel)
        if not dry:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    print("\nDry run only." if dry else "\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
