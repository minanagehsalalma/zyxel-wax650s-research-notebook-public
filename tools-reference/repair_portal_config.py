#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

from prepare_portal_runtime import write_synthetic_portal_blob


def infer_theme(runroot: Path) -> str:
    portal_info = runroot / "var/zyxel/portal_info"
    if portal_info.exists():
        line = portal_info.read_text(encoding="utf-8", errors="ignore").splitlines()[0].strip()
        if line:
            return line.split(":", 1)[0]

    captive_db = runroot / "tmp/captive_profile_db.xml"
    if captive_db.exists():
        match = re.search(r'<captive_profile_list name="([^"]+)"', captive_db.read_text(encoding="utf-8", errors="ignore"))
        if match:
            return match.group(1)

    raise SystemExit("Could not infer portal theme from portal_info or captive_profile_db.xml")


def main() -> int:
    parser = argparse.ArgumentParser(description="Write a synthetic /tmp/portal_config for the Zyxel lab")
    parser.add_argument("--runroot", required=True, help="Prepared Zyxel runroot directory")
    parser.add_argument("--theme", help="Portal theme name. Defaults to the current runtime theme if omitted.")
    parser.add_argument("--post-login-state", type=int)
    parser.add_argument("--post-login-target")
    args = parser.parse_args()

    runroot = Path(args.runroot).resolve()
    if not runroot.is_dir():
        raise SystemExit(f"Runroot not found: {runroot}")

    theme = args.theme or infer_theme(runroot)
    portal_config = runroot / "tmp/portal_config"
    portal_config.parent.mkdir(parents=True, exist_ok=True)

    write_synthetic_portal_blob(
        portal_config,
        theme,
        post_login_state=args.post_login_state,
        post_login_target=args.post_login_target,
    )

    print(f"runroot={runroot}")
    print(f"theme={theme}")
    print(f"portal_config={portal_config}")
    print(f"post_login_state={args.post_login_state}")
    print(f"post_login_target={args.post_login_target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
