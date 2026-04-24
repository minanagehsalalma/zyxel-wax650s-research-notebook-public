#!/usr/bin/env python3
import argparse
import crypt
import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path


MANDATORY_LINKS = {
    "bin": "usr/bin",
    "sbin": "usr/bin",
    "lib": "usr/lib",
    "lib64": "usr/lib",
    "conf": "etc/zyxel/ftp/conf",
    "usr/lib64": "lib",
    "usr/sbin": "bin",
    "etc_writable": "db/etc_writable",
    "usr/lib/ld-musl-aarch64.so.1": "libc.so",
    "usr/lib/libqdecoder.so": "libqdecoder.so.12",
    "usr/lib/libpcre.so.1": "../local/lib/libpcre.so.1.2.2",
    "var/zyxel/raddb": "../../var_ro/zyxel/raddb",
    "var/zyxel/conf/default": "../../var_ro/zyxel/conf/default",
    "etc/zyxel/conf/default": "../../var/zyxel/conf/default",
    "etc/zyxel/ftp": "../../db/etc/zyxel/ftp",
    "etc/zyxel/cert/cacert.pem": "../../../db/cacert.pem",
}

RUNTIME_DIRS = [
    "conf",
    "db/etc_writable/zyxel/conf",
    "db/etc/zyxel/ftp/cert",
    "db/etc/zyxel/ftp/cert/trusted",
    "db/etc/zyxel/ftp/conf",
    "db/etc/zyxel/ftp/captive-portal",
    "db/etc/zyxel/ftp/dev",
    "db/etc/zyxel/ftp/tmp",
    "db/etc/zyxel/ftp/tmp/coredump",
    "etc/zyxel/cert/trusted",
    "dev",
    "proc/net",
    "proc/security",
    "proc/sys/dev/wifi1",
    "proc/sys/dev/wifi2",
    "run/openrc",
    "sys/class/net/eth0/queues/rx-0",
    "sys/class/net/eth0/queues/rx-1",
    "sys/class/net/eth0/queues/rx-2",
    "sys/class/net/eth0/queues/rx-3",
    "sys/class/net/eth1/queues/rx-0",
    "sys/class/net/eth1/queues/rx-1",
    "sys/class/net/eth1/queues/rx-2",
    "sys/class/net/eth1/queues/rx-3",
    "sys/class/net/lo",
    "tmp/captive-portal",
    "tmp/sta_lists",
    "var/empty",
    "var/log",
    "var/run",
    "var/tmp",
    "var/zyxel/cert/https_trusted",
    "var/zyxel/cert/trusted",
    "var/zyxel/key",
    "var/zyxel/net-snmp",
    "var/zyxel/pam.d",
    "var/zyxel/service_conf",
    "var/zyxel/syslog-ng",
    "var/zyxel/zysh",
    "var/zyxel/wlan",
    "var/zyxel/xinetd.d",
]

RUNTIME_FILES = [
    "dev/CP_dev",
    "dev/console",
    "dev/switch0",
    "run/openrc/softlevel",
    "dev/null",
    "proc/net/wireless",
    "var/run/zyshd-init.lock",
    "proc/security/daas",
    "proc/sys/dev/wifi1/dfscac",
    "proc/sys/dev/wifi2/dfscac",
    "var/run/boot-status",
    "var/zyxel/crontab",
    "var/zyxel/clidump.conf",
    "var/zyxel/service_conf/httpd_zld.conf",
    "var/zyxel/service_conf/portal_used.conf",
    "var/zyxel/wlan/wlan-1.conf",
    "var/zyxel/wlan/wlan-2.conf",
    "var/zyxel/wlan/WifiApplyFile-1.conf",
    "var/zyxel/wlan/WifiApplyFile-2.conf",
    "var/zyxel/wlan/wlan-1.log",
    "var/zyxel/wlan/wlan-2.log",
    "var/zyxel/wlan/wlan-3.log",
    "WifiApplyFile-1.conf",
    "WifiApplyFile-2.conf",
    "sys/class/net/eth0/queues/rx-0/rps_cpus",
    "sys/class/net/eth0/queues/rx-1/rps_cpus",
    "sys/class/net/eth0/queues/rx-2/rps_cpus",
    "sys/class/net/eth0/queues/rx-3/rps_cpus",
    "sys/class/net/eth1/queues/rx-0/rps_cpus",
    "sys/class/net/eth1/queues/rx-1/rps_cpus",
    "sys/class/net/eth1/queues/rx-2/rps_cpus",
    "sys/class/net/eth1/queues/rx-3/rps_cpus",
    "tmp/sta_lists/whitelist-sta-slot1",
    "tmp/sta_lists/whitelist-sta-slot2",
    "tmp/sta_lists/whitelist-sta-slot3",
    "tmp/uam-skip-user",
]

MINIMAL_WLAN_CONFIG = """MANAGER_VID="1"
SSID_1_VLAN_ID="1"
WDS_1_VLANID="1"
"""

LAB_ADMIN_PASSWD_LINE = (
    "admin:x:10001:10000:Administration account&admin&120&120&30&0&1&0:"
    "/etc/zyxel/ftp:/bin/zysh"
)


def looks_like_link_placeholder(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    if path.name == "TZ":
        return False
    try:
        data = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return False
    if not data or "\n" in data or "\r" in data:
        return False
    if any(ch.isspace() for ch in data):
        return False
    if data.startswith("ref: "):
        return False
    return all(ch.isalnum() or ch in "._+-/" for ch in data)


def placeholder_target(path: Path, dst_root: Path) -> str | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return None
    if not raw:
        return None
    if raw.startswith("/"):
        candidate = dst_root / raw.lstrip("/")
    else:
        candidate = (path.parent / raw).resolve()
    if candidate.exists():
        if raw.startswith("/"):
            return os.path.relpath(candidate, start=path.parent)
        return raw
    return None


def replace_with_symlink(path: Path, target: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    os.symlink(target, path)


def convert_known_links(dst_root: Path) -> list[str]:
    changed = []
    for rel, target in MANDATORY_LINKS.items():
        path = dst_root / rel
        replace_with_symlink(path, target)
        changed.append(f"{rel} -> {target}")
    return changed


def convert_generic_placeholders(dst_root: Path) -> list[str]:
    changed = []
    progress = True
    while progress:
        progress = False
        for path in sorted(dst_root.rglob("*")):
            if not looks_like_link_placeholder(path):
                continue
            target = placeholder_target(path, dst_root)
            if not target:
                continue
            replace_with_symlink(path, target)
            changed.append(f"{path.relative_to(dst_root)} -> {target}")
            progress = True
    return changed


def build_lab_lighttpd_conf(dst_root: Path) -> str:
    stock_conf = dst_root / "usr/local/lighttpd/conf/lighttpd.conf"
    if not stock_conf.exists():
        raise FileNotFoundError(f"Missing stock lighttpd.conf: {stock_conf}")
    filtered_lines = []
    for line in stock_conf.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("server.tag ="):
            continue
        if stripped.startswith("server.bind ="):
            continue
        if stripped.startswith("server.port ="):
            continue
        filtered_lines.append(line)
    stock_text = "\n".join(filtered_lines) + "\n"
    lab_prefix = "\n".join(
        [
            'server.tag = "zyxel-lab"',
            'server.bind = "127.0.0.1"',
            "server.port = 8080",
            "",
        ]
    )
    return f"{lab_prefix}{stock_text}"


def ensure_runtime(dst_root: Path) -> None:
    for rel in RUNTIME_DIRS:
        path = dst_root / rel
        if path.exists() or path.is_symlink():
            continue
        path.mkdir(parents=True, exist_ok=True)
    for rel in RUNTIME_FILES:
        p = dst_root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if rel == "var/run/boot-status":
            if not p.exists() or p.read_text(encoding="utf-8", errors="ignore").strip() == "":
                p.write_text("0\n", encoding="utf-8")
        elif rel == "proc/security/daas":
            if not p.exists() or p.read_text(encoding="utf-8", errors="ignore").strip() == "":
                p.write_text("1\n", encoding="utf-8")
        else:
            p.touch()
    for rel in ("var/zyxel/resolv.conf", "var/zyxel/services"):
        p = dst_root / rel
        if p.exists() and p.is_dir():
            shutil.rmtree(p)
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            p.touch()
    (dst_root / "usr/local/lighttpd/conf/lighttpd-lab.conf").write_text(
        build_lab_lighttpd_conf(dst_root),
        encoding="utf-8",
    )


def ensure_file_copy(src: Path, dst: Path, changed: list[str], label: str | None = None) -> None:
    if not src.exists() or dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    changed.append(label or f"{dst} <- {src}")


def seed_default_configs(dst_root: Path) -> list[str]:
    changed: list[str] = []
    system_default_src = dst_root / "etc/zyxel/conf/system-default.conf"
    db_conf_dir = dst_root / "db/etc/zyxel/ftp/conf"
    if system_default_src.exists():
        ensure_file_copy(
            system_default_src,
            db_conf_dir / "system-default.conf",
            changed,
            "db/etc/zyxel/ftp/conf/system-default.conf <- etc/zyxel/conf/system-default.conf",
        )
        ensure_file_copy(
            system_default_src,
            db_conf_dir / "startup-config.conf",
            changed,
            "db/etc/zyxel/ftp/conf/startup-config.conf <- etc/zyxel/conf/system-default.conf",
        )
        ensure_file_copy(
            system_default_src,
            db_conf_dir / "lastgood.conf",
            changed,
            "db/etc/zyxel/ftp/conf/lastgood.conf <- etc/zyxel/conf/system-default.conf",
        )

        for name in ("startup-config.conf", "lastgood.conf"):
            conf = db_conf_dir / name
            if conf.exists():
                digest = hashlib.md5(conf.read_bytes()).hexdigest()
                md5_path = conf.with_suffix(conf.suffix + ".md5")
                if not md5_path.exists():
                    md5_path.write_text(f"{digest}  {conf.name}\n", encoding="utf-8")
                    changed.append(f"{md5_path.relative_to(dst_root)} seeded")

    return changed


def seed_certs(dst_root: Path) -> list[str]:
    changed: list[str] = []
    key_src = dst_root / "etc/zyxel/key/server.key"
    global_cert_dir = dst_root / "etc/zyxel/cert"
    ftp_cert_dir = dst_root / "db/etc/zyxel/ftp/cert"
    global_cert = global_cert_dir / "default"
    global_key = global_cert_dir / "default.prv"
    ftp_cert = ftp_cert_dir / "default"
    ftp_key = ftp_cert_dir / "default.prv"
    cacert_src = global_cert_dir / "cacert.buildin.pem"
    db_cacert = dst_root / "db/cacert.pem"
    db_cacert_csum = dst_root / "db/cacert.pem.csum"

    if key_src.exists():
        ensure_file_copy(
            key_src,
            global_key,
            changed,
            "etc/zyxel/cert/default.prv <- etc/zyxel/key/server.key",
        )
        ensure_file_copy(
            key_src,
            ftp_key,
            changed,
            "db/etc/zyxel/ftp/cert/default.prv <- etc/zyxel/key/server.key",
        )

    if key_src.exists() and not global_cert.exists():
        openssl = shutil.which("openssl")
        if openssl:
            global_cert.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    openssl,
                    "req",
                    "-x509",
                    "-new",
                    "-key",
                    str(global_key if global_key.exists() else key_src),
                    "-out",
                    str(global_cert),
                    "-days",
                    "3650",
                    "-sha256",
                    "-subj",
                    "/CN=zyxel-lab",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            changed.append("etc/zyxel/cert/default generated from server.key")
        elif cacert_src.exists():
            shutil.copy2(cacert_src, global_cert)
            changed.append("etc/zyxel/cert/default <- etc/zyxel/cert/cacert.buildin.pem")

    if global_cert.exists():
        ensure_file_copy(
            global_cert,
            ftp_cert,
            changed,
            "db/etc/zyxel/ftp/cert/default <- etc/zyxel/cert/default",
        )

    if cacert_src.exists() and not db_cacert.exists():
        shutil.copy2(cacert_src, db_cacert)
        changed.append("db/cacert.pem <- etc/zyxel/cert/cacert.buildin.pem")
        db_cacert_csum.write_text(
            f"{hashlib.sha256(cacert_src.read_bytes()).hexdigest()}\n",
            encoding="utf-8",
        )
        changed.append("db/cacert.pem.csum seeded")

    return changed


def seed_runtime_files(dst_root: Path, src_root: Path) -> list[str]:
    changed: list[str] = []

    system_default_src = dst_root / "usr/bin/__system_default.xml"
    system_default_dst = dst_root / "db/etc_writable/zyxel/conf/__system_default.xml"
    if system_default_src.exists() and not system_default_dst.exists():
        system_default_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(system_default_src, system_default_dst)
        changed.append("db/etc_writable/zyxel/conf/__system_default.xml <- usr/bin/__system_default.xml")

    mrd_blob_src = src_root.parent / "bin_images/mrd-WAX650S.bin"
    mrd_dst = dst_root / "proc/MRD"
    if mrd_blob_src.exists() and (not mrd_dst.exists() or mrd_dst.stat().st_size == 0):
        mrd_dst.parent.mkdir(parents=True, exist_ok=True)
        mrd_dst.write_bytes(mrd_blob_src.read_bytes()[-240:])
        changed.append("proc/MRD <- bin_images/mrd-WAX650S.bin tail")

    dhcpc_src = dst_root / "etc/dhcpc/dhcpcd.exe"
    dhcpc_dst = dst_root / "var/zyxel/zysh/dhcpcd.exe"
    if dhcpc_src.exists() and not dhcpc_dst.exists():
        dhcpc_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dhcpc_src, dhcpc_dst)
        changed.append("var/zyxel/zysh/dhcpcd.exe <- etc/dhcpc/dhcpcd.exe")

    country_src = dst_root / "etc/wlan/country_list_EU"
    country_dst = dst_root / "var/zyxel/wlan/country_list"
    if country_src.exists() and not country_dst.exists():
        shutil.copy2(country_src, country_dst)
        changed.append("var/zyxel/wlan/country_list <- etc/wlan/country_list_EU")

    for rel in ("var/zyxel/wlan/wlan-1.conf", "var/zyxel/wlan/wlan-2.conf"):
        wlan_conf = dst_root / rel
        if wlan_conf.exists() and wlan_conf.stat().st_size == 0:
            wlan_conf.write_text(MINIMAL_WLAN_CONFIG, encoding="utf-8")
            changed.append(f"{rel} seeded")

    for rel in ("var/zyxel/wlan/wlan-1.conf", "var/zyxel/wlan/wlan-2.conf"):
        wlan_conf = dst_root / rel
        wlan_backup = wlan_conf.with_suffix(".conf.bak")
        if wlan_conf.exists() and not wlan_backup.exists():
            shutil.copy2(wlan_conf, wlan_backup)
            changed.append(f"{wlan_backup.relative_to(dst_root)} <- {wlan_conf.relative_to(dst_root)}")

    for src_rel, dst_rel in (
        ("var/zyxel/wlan/wlan-1.conf", "var/zyxel/wlan/WifiApplyFile-1.conf"),
        ("var/zyxel/wlan/wlan-2.conf", "var/zyxel/wlan/WifiApplyFile-2.conf"),
        ("var/zyxel/wlan/wlan-1.conf", "WifiApplyFile-1.conf"),
        ("var/zyxel/wlan/wlan-2.conf", "WifiApplyFile-2.conf"),
    ):
        src = dst_root / src_rel
        dst = dst_root / dst_rel
        if src.exists() and dst.exists() and dst.stat().st_size == 0:
            shutil.copy2(src, dst)
            changed.append(f"{dst_rel} <- {src_rel}")

    pam_src = dst_root / "etc/pam.d.basic"
    pam_dst = dst_root / "var/zyxel/pam.d"
    if pam_src.exists() and not any(pam_dst.iterdir()):
        shutil.copytree(pam_src, pam_dst, dirs_exist_ok=True)
        changed.append("var/zyxel/pam.d <- etc/pam.d.basic/*")

    xinetd_src = dst_root / "etc/xinetd.d"
    xinetd_dst = dst_root / "var/zyxel/xinetd.d"
    if xinetd_src.exists() and not any(xinetd_dst.iterdir()):
        shutil.copytree(xinetd_src, xinetd_dst, dirs_exist_ok=True)
        changed.append("var/zyxel/xinetd.d <- etc/xinetd.d/*")

    services_src = dst_root / "etc/services.basic"
    services_dst = dst_root / "var/zyxel/services"
    if services_src.exists() and services_dst.is_file() and services_dst.stat().st_size == 0:
        shutil.copy2(services_src, services_dst)
        changed.append("var/zyxel/services <- etc/services.basic")

    resolv_src = dst_root / "etc/resolv.conf.basic"
    resolv_dst = dst_root / "var/zyxel/resolv.conf"
    if resolv_src.exists() and resolv_dst.is_file() and resolv_dst.stat().st_size == 0:
        shutil.copy2(resolv_src, resolv_dst)
        changed.append("var/zyxel/resolv.conf <- etc/resolv.conf.basic")

    syslog_src = dst_root / "etc/syslog-ng/syslog-ng.conf"
    syslog_dst = dst_root / "var/zyxel/syslog-ng/syslog-ng.conf"
    if syslog_src.exists() and not syslog_dst.exists():
        syslog_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(syslog_src, syslog_dst)
        changed.append("var/zyxel/syslog-ng/syslog-ng.conf <- etc/syslog-ng/syslog-ng.conf")

    tz_src = dst_root / "etc/TZ"
    tz_dst = dst_root / "var/zyxel/TZ"
    if tz_src.exists() and not tz_dst.exists():
        tz_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tz_src, tz_dst)
        changed.append("var/zyxel/TZ <- etc/TZ")

    startup_cfg = dst_root / "db/etc/zyxel/ftp/conf/startup-config.conf"
    startup_md5 = dst_root / "etc/zyxel/ftp/conf/startup-config.conf.md5"
    if startup_cfg.exists() and not startup_md5.exists():
        startup_md5.parent.mkdir(parents=True, exist_ok=True)
        startup_md5.write_text("", encoding="utf-8")
        changed.append("etc/zyxel/ftp/conf/startup-config.conf.md5 touched")

    fwversion = dst_root / "db/fwversion"
    if not fwversion.exists():
        fwversion.parent.mkdir(parents=True, exist_ok=True)
        fwversion.write_text(
            "\n".join(
                [
                    "FIRMWARE_VER=7.10(###.4)",
                    "MODEL_ID=WAX650",
                    "CAPWAP_VER=1.00.04",
                    "COMPATIBLE_PRODUCT_MODEL_0=54E1",
                    "COMPATIBLE_PRODUCT_MODEL_1=FFFF",
                    "COMPATIBLE_PRODUCT_MODEL_2=FFFF",
                    "COMPATIBLE_PRODUCT_MODEL_3=FFFF",
                    "COMPATIBLE_PRODUCT_MODEL_4=FFFF",
                    "BUILD_DATE=2026-01-12 14:08:11",
                    "FSH_VER=1.0.0",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        changed.append("db/fwversion seeded from etc/os-release metadata")

    rw_fwversion = dst_root / "rw/fwversion"
    if fwversion.exists() and not rw_fwversion.exists():
        rw_fwversion.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fwversion, rw_fwversion)
        changed.append("rw/fwversion <- db/fwversion")

    host_qemu = Path("/usr/bin/qemu-aarch64-static")
    qemu_dst = dst_root / "usr/bin/qemu-aarch64-static"
    if host_qemu.exists() and not qemu_dst.exists():
        qemu_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(host_qemu, qemu_dst)
        changed.append("usr/bin/qemu-aarch64-static <- host /usr/bin/qemu-aarch64-static")

    portal_cgi_tmp = dst_root / "usr/local/lighttpd/cgi-bin/tmp"
    portal_cgi_tmp.mkdir(parents=True, exist_ok=True)
    portal_cgi_link = portal_cgi_tmp / "captive-portal"
    if not portal_cgi_link.exists():
        replace_with_symlink(portal_cgi_link, "/tmp/captive-portal")
        changed.append("usr/local/lighttpd/cgi-bin/tmp/captive-portal -> /tmp/captive-portal")

    return changed


def hash_lab_admin_password(password: str, salt: str = "LabSalt42") -> str:
    return crypt.crypt(password, f"$5${salt}$")


def replace_admin_flat_password(path: Path, password_hash: str) -> bool:
    if not path.exists():
        return False
    original = path.read_text(encoding="utf-8", errors="ignore")
    updated = re.sub(
        r"^username admin .* user-type admin$",
        f"username admin encrypted-password {password_hash} user-type admin",
        original,
        flags=re.MULTILINE,
    )
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def replace_admin_xml_password(path: Path, password_hash: str) -> bool:
    if not path.exists():
        return False
    original = path.read_text(encoding="utf-8", errors="ignore")
    updated = re.sub(
        r'(<in_user_t name="admin">.*?<password>)(.*?)(</password>)',
        rf"\g<1>{password_hash}\g<3>",
        original,
        count=1,
        flags=re.DOTALL,
    )
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def ensure_admin_shadow(path: Path, password_hash: str) -> bool:
    if not path.exists():
        return False
    original = path.read_text(encoding="utf-8", errors="ignore")
    admin_line = f"admin:{password_hash}:20565::99999::::"
    if re.search(r"^admin:.*$", original, flags=re.MULTILINE):
        updated = re.sub(r"^admin:.*$", admin_line, original, count=1, flags=re.MULTILINE)
    else:
        updated = original.rstrip("\n") + "\n" + admin_line + "\n"
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def ensure_admin_passwd(path: Path) -> bool:
    if not path.exists():
        return False
    original = path.read_text(encoding="utf-8", errors="ignore")
    if re.search(r"^admin:", original, flags=re.MULTILINE):
        return False
    updated = original.rstrip("\n") + "\n" + LAB_ADMIN_PASSWD_LINE + "\n"
    path.write_text(updated, encoding="utf-8")
    return True


def refresh_conf_md5(path: Path) -> bool:
    md5_path = path.with_suffix(path.suffix + ".md5")
    digest = hashlib.md5(path.read_bytes()).hexdigest()
    content = f"{digest}  {path.name}\n"
    if md5_path.exists() and md5_path.read_text(encoding="utf-8", errors="ignore") == content:
        return False
    md5_path.write_text(content, encoding="utf-8")
    return True


def seed_lab_admin_state(dst_root: Path, password: str) -> list[str]:
    changed: list[str] = []
    password_hash = hash_lab_admin_password(password)

    flat_conf_paths = [
        dst_root / "etc/zyxel/conf/system-default.conf",
        dst_root / "db/etc/zyxel/ftp/conf/system-default.conf",
        dst_root / "db/etc/zyxel/ftp/conf/startup-config.conf",
        dst_root / "db/etc/zyxel/ftp/conf/lastgood.conf",
    ]
    for path in flat_conf_paths:
        if replace_admin_flat_password(path, password_hash):
            changed.append(f"{path.relative_to(dst_root)} admin password seeded")
        if path.name in {"startup-config.conf", "lastgood.conf"} and path.exists():
            if refresh_conf_md5(path):
                changed.append(f"{path.relative_to(dst_root)}.md5 refreshed")

    if ensure_admin_passwd(dst_root / "var/zyxel/passwd"):
        changed.append("var/zyxel/passwd admin entry seeded")
    if ensure_admin_shadow(dst_root / "var/zyxel/shadow", password_hash):
        changed.append("var/zyxel/shadow admin hash seeded")

    for path in (
        dst_root / "db/etc_writable/zyxel/conf/startup-config.conf.xml",
        dst_root / "db/etc_writable/zyxel/conf/__system_default.xml",
        dst_root / "tmp/template_user.xml",
        dst_root / "usr/bin/__system_default.xml",
    ):
        if replace_admin_xml_password(path, password_hash):
            changed.append(f"{path.relative_to(dst_root)} admin password seeded")

    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare a runnable scratch Zyxel rootfs")
    parser.add_argument("--src", required=True, help="Source extracted rootfs")
    parser.add_argument("--dst", required=True, help="Destination scratch rootfs")
    parser.add_argument("--rebuild", action="store_true", help="Delete and rebuild destination")
    args = parser.parse_args()

    src = Path(args.src).resolve()
    dst = Path(args.dst).resolve()
    if not src.is_dir():
        raise SystemExit(f"Source rootfs not found: {src}")

    if dst.exists() and args.rebuild:
        shutil.rmtree(dst)
    if not dst.exists():
        shutil.copytree(src, dst, symlinks=False)

    changed = []
    changed.extend(convert_known_links(dst))
    ensure_runtime(dst)
    changed.extend(convert_generic_placeholders(dst))
    changed.extend(seed_default_configs(dst))
    changed.extend(seed_certs(dst))
    changed.extend(seed_runtime_files(dst, src))
    lab_admin_password = os.environ.get("ZYXEL_LAB_ADMIN_PASSWORD", "")
    if lab_admin_password:
        changed.extend(seed_lab_admin_state(dst, lab_admin_password))
    changed.extend(convert_generic_placeholders(dst))

    print(f"Prepared run-root: {dst}")
    print(f"Mandatory placeholder fixes: {len(MANDATORY_LINKS)}")
    print(f"Additional converted placeholders: {max(0, len(changed) - len(MANDATORY_LINKS))}")
    for item in changed[:80]:
        print(item)
    if len(changed) > 80:
        print(f"... {len(changed) - 80} more")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
