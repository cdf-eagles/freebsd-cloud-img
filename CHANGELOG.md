# Changelog

- 2026-10-03
  - The build VM action `vmactions/freebsd-vm` is updated from v1.5.2 to v1.5.9. The inputs the workflow uses are unchanged, and the new version is first exercised by a manual run or the monthly schedule because the image build does not run on a workflow-only pull request.
  - Pull requests and pushes that change a shell script now also syntax-check and shellcheck the `cloudify.sh` that `build.sh` generates, for a normal and a debug build (`scripts/check_cloudify.sh`, about a second). Before, only `build.sh` itself was checked, and its `cloudify.sh` heredoc was never parsed as a script.
  - The image build and web publish workflows run on a closed pull request only when it was merged. Before, a pull request closed without merging still built the images or published the web files and uploaded them to S3.
  - The RAW image is created with `truncate -s` instead of `dd` and compressed with `gzip -1` instead of `gzip -9`. On the 2026-10-03 run these two steps took about 100 s and 420 s of 1046 s.
  - The ZFS and UFS images build in parallel as a matrix, and a final job publishes both to S3 only when both succeed. Before, one job built them one after the other.
  - `ROOT_FS` in the environment now selects the root filesystem, as the usage text documents. The script read `ROOTFS` instead, so `ROOT_FS` was ignored.
  - `-d` now sets `DEBUG`, so a debug build sets the root password in the image as documented. Before, `-d` only enabled shell tracing and verbose tar output.
  - The root account is now locked in built images (`pw usermod -n root -w no`). The command was appended to `cloudify.sh` after its `exit 0` and never ran.
  - cloud-init is installed from the package matching the installed Python (`py312-cloud-init`) instead of a fixed `py311-cloud-init`, which the package repository no longer carries. Images built from 2026-07-15 to 2026-10-03 lack cloud-init, python3, qemu-guest-agent and ca_root_nss.
  - The build now fails if a package install fails or a required package is missing afterwards. Before, the build passed and uploaded the incomplete image.
  - Builds default to FreeBSD 15.1-RELEASE and the build VM is pinned to 15.1. 15.0-RELEASE reached end-of-life on 2026-09-30.
  - The build stops with an explicit error when `freebsd-update` reports an end-of-life release. Before, it ended with only `ssh exited with code 1`.
- 2026-09-28
  - The build-time pkg configuration is now removed from the image. The cleanup had misplaced quotes and never matched, so every earlier image kept the ABI pin and the plain-http repository override.
