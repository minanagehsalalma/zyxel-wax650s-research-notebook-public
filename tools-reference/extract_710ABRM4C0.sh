#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <firmware.bin> <output-dir> [standalone.conf]" >&2
  exit 1
fi

FIRMWARE_BIN="$(readlink -f "$1")"
OUTDIR="$(readlink -m "$2")"
STANDALONE_CONF="${3:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

need_cmd dumpimage
need_cmd fdtget
need_cmd ubireader_extract_images
need_cmd unsquashfs
need_cmd sha256sum

[[ -f "$FIRMWARE_BIN" ]] || {
  echo "Firmware not found: $FIRMWARE_BIN" >&2
  exit 1
}

mkdir -p "$OUTDIR/bin_images"
TMPDIR="$OUTDIR/.tmp_ubi_imgs"
rm -rf "$TMPDIR"

if [[ -n "$STANDALONE_CONF" ]]; then
  cp "$STANDALONE_CONF" "$OUTDIR/$(basename "$STANDALONE_CONF")"
fi

mapfile -t FIT_NODES < <(fdtget -l "$FIRMWARE_BIN" /images)
for idx in "${!FIT_NODES[@]}"; do
  node="${FIT_NODES[$idx]}"
  desc="$(fdtget -ts "$FIRMWARE_BIN" "/images/$node" description)"
  # The FIT contains two entries described as ff.bin. The original extracted tree
  # keeps a single ff.bin on disk, so this intentionally matches that layout.
  dumpimage -T flat_dt -p "$idx" -o "$OUTDIR/bin_images/$desc" "$FIRMWARE_BIN" >/dev/null
done

ROOT_UBI="$OUTDIR/bin_images/openwrt-ipq-ipq807x_64-ubi-root.img"
[[ -f "$ROOT_UBI" ]] || {
  echo "Expected root UBI image not found: $ROOT_UBI" >&2
  exit 1
}

ubireader_extract_images -o "$TMPDIR" "$ROOT_UBI" >/dev/null

ROOTFS_IMG="$TMPDIR/openwrt-ipq-ipq807x_64-ubi-root.img/img-695833001_vol-ubi_rootfs.ubifs"
[[ -f "$ROOTFS_IMG" ]] || {
  echo "Expected rootfs volume not found: $ROOTFS_IMG" >&2
  exit 1
}

# Despite the suffix, the main rootfs volume is SquashFS on this build.
rm -rf "$OUTDIR/rootfs"
unsquashfs -d "$OUTDIR/rootfs" "$ROOTFS_IMG" >/dev/null

echo "Firmware: $FIRMWARE_BIN"
sha256sum "$FIRMWARE_BIN"
echo "FIT image outputs: $(find "$OUTDIR/bin_images" -maxdepth 1 -type f | wc -l)"
echo "Rootfs extracted to: $OUTDIR/rootfs"
