# Changelog

- 2026-10-03: `ROOT_FS` in the environment now selects the root filesystem, as the usage text documents. The script read `ROOTFS` instead, so `ROOT_FS` was ignored.
- 2026-10-03: `-d` now sets `DEBUG`, so a debug build sets the root password in the image as documented. Before, `-d` only enabled shell tracing and verbose tar output.
- 2026-10-03: The root account is now locked in built images (`pw usermod -n root -w no`). The command was appended to `cloudify.sh` after its `exit 0` and never ran.
- 2026-10-03: cloud-init is installed from the package matching the installed Python (`py312-cloud-init`) instead of a fixed `py311-cloud-init`, which the package repository no longer carries. Images built from 2026-07-15 to 2026-10-03 lack cloud-init, python3, qemu-guest-agent and ca_root_nss.
- 2026-10-03: The build now fails if a package install fails or a required package is missing afterwards. Before, the build passed and uploaded the incomplete image.
- 2026-10-03: Builds default to FreeBSD 15.1-RELEASE and the build VM is pinned to 15.1. 15.0-RELEASE reached end-of-life on 2026-09-30.
- 2026-10-03: The build stops with an explicit error when `freebsd-update` reports an end-of-life release. Before, it ended with only `ssh exited with code 1`.
- 2026-09-28: The build-time pkg configuration is now removed from the image. The cleanup had misplaced quotes and never matched, so every earlier image kept the ABI pin and the plain-http repository override.
