# Tool References

Selected helper scripts are included for reproducibility and future analysis.

They document the lab model:

- rootfs preparation
- `bubblewrap` and `qemu-aarch64-static` execution
- UAM socket simulation
- IPC seeding
- portal runtime repair
- focused replay/probe helpers

These files are references, not a complete runnable distribution. The raw firmware image, extracted rootfs, and `runroot` are intentionally excluded.

See [MANIFEST.md](MANIFEST.md) for the copied helper list.

One extra helper is included here on purpose: [extract_710ABRM4C0.sh](extract_710ABRM4C0.sh). Unlike the rest of this folder, that script is not a lab helper copied from the workspace. It is a reconstructed, verified extractor for this exact firmware build so the notebook now documents the firmware-to-rootfs path concretely.
