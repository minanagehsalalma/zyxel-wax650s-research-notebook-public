#!/usr/bin/env python3
import argparse
import copy
import json
import shutil
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET


HOSTNAME = "nap-slogin.nebula.zyxel.com"
PORTAL_CONFIG_SIZE = 9183
PORTAL_RECORD_SIZE = 1020
PORTAL_RECORD_COUNT = 8
PORTAL_RECORD_KEY_OFFSET = 0x80
PORTAL_RECORD_POST_LOGIN_STATE_OFFSET = 0x1E4
PORTAL_RECORD_POST_LOGIN_TARGET_OFFSET = 0x1E8


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_text(path: Path, content: str) -> None:
    ensure_parent(path)
    path.write_text(content, encoding="utf-8")


def write_bytes(path: Path, content: bytes) -> None:
    ensure_parent(path)
    path.write_bytes(content)


def first_child(parent: ET.Element, tag: str) -> ET.Element:
    child = parent.find(tag)
    if child is None:
        raise ValueError(f"Missing expected XML tag: {tag}")
    return child


def set_child_text(parent: ET.Element, tag: str, value: str) -> None:
    child = first_child(parent, tag)
    child.text = value


def ensure_child_text(parent: ET.Element, tag: str, value: str) -> None:
    child = parent.find(tag)
    if child is None:
        child = ET.SubElement(parent, tag)
    child.text = value


def render_login_html(theme: str) -> str:
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{theme} captive portal</title>
</head>
<body>
  <h1>{theme} captive portal</h1>
  <p>Synthetic-minimal captive portal bootstrap.</p>
  <form method="post" action="/cgi-bin/Clicktocontinue.cgi">
    <button type="submit">Continue</button>
  </form>
</body>
</html>
"""


def render_success_html(theme: str) -> str:
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{theme} success</title>
</head>
<body>
  <h1>{theme} success</h1>
  <p>If the portal flow works, the CGI should have already issued the guest cookie.</p>
</body>
</html>
"""


def synthetic_captive_profile(theme: str) -> str:
    return "\n".join(
        [
            "!",
            f"captive-portal-profile {theme}",
            " method click-through",
            " portal-type internal",
            " success-page internal",
            " simultaneous-logins Allow",
            " keep-previous-user no",
            " max-login-count 1",
            "!",
            "write",
            "!",
            "",
        ]
    )


def synthetic_ssid_profile(theme: str) -> str:
    return "\n".join(
        [
            "!",
            "wlan-ssid-profile SSID1",
            " ssid zyxel-lab",
            f" captive-portal {theme}",
            " guest-ssid",
            "!",
            "write",
            "!",
            "",
        ]
    )


def synthetic_portal_metadata(
    theme: str,
    mode: str,
    post_login_state: int | None,
    post_login_target: str | None,
    write_portal_config: bool,
    seed_system_default_profile: bool,
    seed_radio_profile_slots: bool,
) -> dict[str, object]:
    notes = [
        "portal_config now seeds one deterministic record keyed by the active theme string",
        "theme assets are hydrated locally to satisfy /CP/... and direct CGI file lookups",
    ]
    if not write_portal_config:
        notes.append(
            "portal_config write is intentionally skipped so the lab can test whether a vendor path creates it"
        )
    if post_login_state is not None:
        notes.append(
            "post-login state override is active; this is a diagnostic aid, not a faithful vendor blob"
        )
    if post_login_target:
        notes.append(
            "post-login redirect target override is active; this is a diagnostic aid, not a faithful vendor blob"
        )
    if seed_system_default_profile:
        notes.append(
            "__system_default.xml is patched with a diagnostic captive profile and SSID binding; this is synthetic but vendor-schema aligned"
        )
    if seed_radio_profile_slots:
        notes.append(
            "__system_default.xml is also patched with synthetic radio-profile SSID slot bindings; this is experimental and only for runtime-fidelity testing"
        )

    return {
        "mode": mode,
        "theme": theme,
        "host": HOSTNAME,
        "portal_config_size": PORTAL_CONFIG_SIZE,
        "portal_record_size": PORTAL_RECORD_SIZE,
        "portal_record_count": PORTAL_RECORD_COUNT,
        "portal_lookup_key": theme,
        "write_portal_config": write_portal_config,
        "seed_system_default_profile": seed_system_default_profile,
        "seed_radio_profile_slots": seed_radio_profile_slots,
        "post_login_state_override": post_login_state,
        "post_login_target_override": post_login_target,
        "notes": notes,
    }


def write_synthetic_portal_blob(
    path: Path,
    theme: str,
    post_login_state: int | None = None,
    post_login_target: str | None = None,
) -> None:
    blob = bytearray(PORTAL_CONFIG_SIZE)
    key = theme.encode("ascii", errors="strict")
    if len(key) >= PORTAL_RECORD_SIZE - PORTAL_RECORD_KEY_OFFSET:
        raise ValueError(f"Theme name is too long for portal record: {theme}")
    blob[PORTAL_RECORD_KEY_OFFSET:PORTAL_RECORD_KEY_OFFSET + len(key)] = key
    blob[PORTAL_RECORD_KEY_OFFSET + len(key)] = 0
    if post_login_state is not None:
        if post_login_state < 0:
            raise ValueError("post_login_state must be >= 0")
        blob[
            PORTAL_RECORD_POST_LOGIN_STATE_OFFSET:PORTAL_RECORD_POST_LOGIN_STATE_OFFSET + 4
        ] = int(post_login_state).to_bytes(4, "little", signed=False)
    if post_login_target is not None:
        target = post_login_target.encode("ascii", errors="strict") + b"\x00"
        max_len = PORTAL_RECORD_SIZE - PORTAL_RECORD_POST_LOGIN_TARGET_OFFSET
        if len(target) > max_len:
            raise ValueError("post_login_target is too long for the portal record")
        blob[
            PORTAL_RECORD_POST_LOGIN_TARGET_OFFSET:PORTAL_RECORD_POST_LOGIN_TARGET_OFFSET + len(target)
        ] = target
    write_bytes(path, bytes(blob))


def write_lighttpd_includes(runroot: Path, theme: str) -> None:
    service_conf = runroot / "var/zyxel/service_conf"
    include_rel = f"/var/zyxel/service_conf/captive_portal_{theme}.conf"
    include_path = service_conf / f"captive_portal_{theme}.conf"
    include_body = "\n".join(
        [
            f'# synthetic portal bootstrap for {theme}',
            f'$HTTP["host"] == "{HOSTNAME}" {{',
            f'  url.redirect = ( "^/$" => "/CP/{theme}/login.html" )',
            "}",
            "",
        ]
    )
    write_text(include_path, include_body)
    write_text(service_conf / "portal_used.conf", f'include "{include_rel}"\n')


def hydrate_synthetic_assets(runroot: Path, theme: str) -> None:
    theme_dir = runroot / "tmp/captive-portal" / theme
    theme_dir.mkdir(parents=True, exist_ok=True)
    write_text(theme_dir / "login.html", render_login_html(theme))
    write_text(theme_dir / "success.html", render_success_html(theme))


def hydrate_vendor_assets(runroot: Path, theme: str) -> bool:
    zip_dir_candidates = [
        runroot / "db/etc/zyxel/ftp/captive-portal",
        runroot / "etc/zyxel/ftp/captive-portal",
    ]
    target_dir = runroot / "tmp/captive-portal" / theme
    target_dir.mkdir(parents=True, exist_ok=True)

    extracted = False
    for zip_dir in zip_dir_candidates:
        login_zip = zip_dir / f"{theme}.zip"
        success_zip = zip_dir / f"{theme}-success.zip"
        for archive in (login_zip, success_zip):
            if not archive.exists():
                continue
            with zipfile.ZipFile(archive) as zf:
                zf.extractall(target_dir)
            extracted = True
    return extracted


def bootstrap_state(
    runroot: Path,
    theme: str,
    mode: str,
    post_login_state: int | None,
    post_login_target: str | None,
    write_portal_config: bool,
    seed_system_default_profile: bool = False,
    seed_radio_profile_slots: bool = False,
) -> None:
    write_bytes(runroot / "tmp/cp_simulate", b"")
    if write_portal_config:
        write_synthetic_portal_blob(
            runroot / "tmp/portal_config",
            theme,
            post_login_state=post_login_state,
            post_login_target=post_login_target,
        )

    captive_profile = synthetic_captive_profile(theme)
    ssid_profile = synthetic_ssid_profile(theme)
    for rel, content in (
        ("tmp/captive-profile.config", captive_profile),
        ("tmp/captive-profile.config.bak", captive_profile),
        ("tmp/ssid_profile.config", ssid_profile),
        ("tmp/ssid_profile.config.bak", ssid_profile),
    ):
        write_text(runroot / rel, content)

    meta_path = runroot / "tmp/portal-bootstrap.json"
    write_text(
        meta_path,
        json.dumps(
            synthetic_portal_metadata(
                theme,
                mode,
                post_login_state,
                post_login_target,
                write_portal_config,
                seed_system_default_profile,
                seed_radio_profile_slots,
            ),
            indent=2,
        )
        + "\n",
    )


def clear_existing_theme(runroot: Path, theme: str) -> None:
    theme_dir = runroot / "tmp/captive-portal" / theme
    if theme_dir.exists():
        shutil.rmtree(theme_dir)


def seed_system_default_portal_profile(runroot: Path, theme: str, ssid_profile: str, ssid_name: str) -> None:
    system_default = runroot / "db/etc_writable/zyxel/conf/__system_default.xml"
    if not system_default.exists():
        raise FileNotFoundError(f"System default XML not found: {system_default}")

    tree = ET.parse(system_default)
    root = tree.getroot()

    captive_container = root.find(".//captiveprofile")
    ssid_container = root.find(".//ssidprofile")
    hybrid_var = root.find(".//wsys_env/string_t[@name='hybrid-mode']/var")
    if captive_container is None or ssid_container is None or hybrid_var is None:
        raise ValueError("System default XML is missing required captive portal sections")

    captive_list = first_child(captive_container, "list")
    captive_default = captive_container.find("./captive_profile_list[@name='default']")
    if captive_default is None:
        raise ValueError("Missing default captive profile node")
    captive_node = captive_container.find(f"./captive_profile_list[@name='{theme}']")
    if captive_node is None:
        captive_node = copy.deepcopy(captive_default)
        captive_container.append(captive_node)
    captive_node.set("name", theme)
    captive_node.set("Description", "")
    captive_node.set("Changed", "yes")
    set_child_text(captive_node, "Captive_portal", "click-through")
    set_child_text(captive_node, "Simultaneous_login", "Allow")
    set_child_text(captive_node, "Keep_previous_user_activate", "no")
    set_child_text(captive_node, "Max_login_count", "1")
    set_child_text(captive_node, "Captive_portal_type", "internal")
    set_child_text(captive_node, "Success_page", "internal")
    set_child_text(captive_node, "Ext_page_url", "")
    set_child_text(captive_node, "Promotion_url", "")
    if not any((entity.text or "").strip() == theme for entity in captive_list.findall("entity")):
        entity = ET.Element("entity")
        entity.text = theme
        captive_list.append(entity)

    ssid_list = first_child(ssid_container, "list")
    ssid_default = ssid_container.find("./ssid_profile_list[@name='default']")
    if ssid_default is None:
        raise ValueError("Missing default SSID profile node")
    ssid_node = ssid_container.find(f"./ssid_profile_list[@name='{ssid_profile}']")
    if ssid_node is None:
        ssid_node = copy.deepcopy(ssid_default)
        ssid_container.append(ssid_node)
    ssid_node.set("name", ssid_profile)
    ssid_node.set("Id", "2")
    ssid_node.set("Description", "")
    ssid_node.set("Changed", "yes")
    set_child_text(ssid_node, "SSID", ssid_name)
    set_child_text(ssid_node, "Captive_profile", theme)
    if not any((entity.text or "").strip() == ssid_profile for entity in ssid_list.findall("entity")):
        entity = ET.Element("entity")
        entity.text = ssid_profile
        ssid_list.append(entity)

    hybrid_var.text = "cloud"
    tree.write(system_default, encoding="unicode")


def seed_system_default_radio_slots(runroot: Path, ssid_profile: str) -> None:
    system_default = runroot / "db/etc_writable/zyxel/conf/__system_default.xml"
    if not system_default.exists():
        raise FileNotFoundError(f"System default XML not found: {system_default}")

    tree = ET.parse(system_default)
    root = tree.getroot()

    radio_profiles = root.findall(".//radioprofile/radio_profile_list")
    if not radio_profiles:
        raise ValueError("System default XML is missing radio_profile_list nodes")

    for radio_node in radio_profiles:
        ensure_child_text(radio_node, "SSID_profile_1", ssid_profile)
        for idx in range(2, 9):
            ensure_child_text(radio_node, f"SSID_profile_{idx}", "")

    tree.write(system_default, encoding="unicode")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap captive portal runtime files for the Zyxel lab")
    parser.add_argument("--runroot", required=True, help="Prepared Zyxel runroot directory")
    parser.add_argument("--mode", choices=("synthetic-minimal", "vendor"), default="synthetic-minimal")
    parser.add_argument("--theme", default="THEME1")
    parser.add_argument("--ssid-profile", default="SSID1")
    parser.add_argument("--ssid-name", default="zyxel-lab")
    parser.add_argument("--post-login-state", type=int)
    parser.add_argument("--post-login-target")
    parser.add_argument("--write-includes", action="store_true")
    parser.add_argument("--hydrate-assets", action="store_true")
    parser.add_argument("--bootstrap-state", action="store_true")
    parser.add_argument(
        "--seed-system-default-profile",
        action="store_true",
        help="Patch __system_default.xml with a diagnostic captive profile and SSID binding",
    )
    parser.add_argument(
        "--skip-portal-config",
        action="store_true",
        help="Seed supporting portal runtime files but do not pre-write /tmp/portal_config",
    )
    parser.add_argument(
        "--seed-radio-profile-slots",
        action="store_true",
        help="Patch __system_default.xml radio_profile_list nodes with synthetic SSID_profile_1..8 fields for runtime-fidelity experiments",
    )
    args = parser.parse_args()

    runroot = Path(args.runroot).resolve()
    if not runroot.is_dir():
        raise SystemExit(f"Runroot not found: {runroot}")

    selected = any((args.write_includes, args.hydrate_assets, args.bootstrap_state))
    do_includes = args.write_includes or not selected
    do_assets = args.hydrate_assets or not selected
    do_state = args.bootstrap_state or not selected

    clear_existing_theme(runroot, args.theme)

    if do_includes:
        write_lighttpd_includes(runroot, args.theme)

    if do_assets:
        vendor_ok = False
        if args.mode == "vendor":
            vendor_ok = hydrate_vendor_assets(runroot, args.theme)
        if args.mode == "synthetic-minimal" or not vendor_ok:
            hydrate_synthetic_assets(runroot, args.theme)

    if do_state:
        bootstrap_state(
            runroot,
            args.theme,
            args.mode,
            args.post_login_state,
            args.post_login_target,
            not args.skip_portal_config,
            args.seed_system_default_profile,
            args.seed_radio_profile_slots,
        )

    if args.seed_system_default_profile:
        seed_system_default_portal_profile(runroot, args.theme, args.ssid_profile, args.ssid_name)
    if args.seed_radio_profile_slots:
        seed_system_default_radio_slots(runroot, args.ssid_profile)

    print(f"runroot={runroot}")
    print(f"mode={args.mode}")
    print(f"theme={args.theme}")
    print(f"ssid_profile={args.ssid_profile}")
    print(f"ssid_name={args.ssid_name}")
    print(f"post_login_state={args.post_login_state}")
    print(f"post_login_target={args.post_login_target}")
    print(f"write_includes={do_includes}")
    print(f"hydrate_assets={do_assets}")
    print(f"bootstrap_state={do_state}")
    print(f"seed_system_default_profile={args.seed_system_default_profile}")
    print(f"seed_radio_profile_slots={args.seed_radio_profile_slots}")
    print(f"write_portal_config={not args.skip_portal_config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
