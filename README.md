[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![main](https://img.shields.io/badge/main-stable-green.svg?maxAge=2592000)](https://github.com/cdf-eagles/freebsd-cloud-img/tree/main)
[![Build FreeBSD Cloud Images](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/generate_image.yml/badge.svg)](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/generate_image.yml)
[![Publish Web Artifacts](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/publish_web.yml/badge.svg)](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/publish_web.yml)
[![CI](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/ci.yml/badge.svg)](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/ci.yml)

# FreeBSD Cloud-Image (bhyve)
This is a script/repository for generating an UNOFFICIAL FreeBSD cloud-init enabled image for use with bhyve. These images may also work with OpenStack and/or NoCloud environments.

Original code was taken from [Virt-Lightning](https://github.com/virt-lightning/freebsd-cloud-images).

# Usage
```
Usage: build.sh [-d] [-v] [-r <FreeBSD Release>] [-f <root fstype>]
  -d,    Enable debug mode for script AND image (sets a root password in the image).    EnvVar:DEBUG
  -r,    FreeBSD Release to download. [Default: 15.1]                                   EnvVar:RELEASE
  -f,    Root filesystem type (zfs or ufs). [Default: zfs]                              EnvVar:ROOT_FS
  -v,    Script version information.
  -h,    Display usage.
```

A build stops with an explanatory error once the selected release has passed its end-of-life date (`freebsd-update` refuses to continue). Pick a [supported release](https://www.freebsd.org/security/#sup) and, for the monthly workflow, update the `RELEASE` default in `scripts/build.sh` and the `release` of the build VM in `.github/workflows/generate_image.yml`.

The release is downloaded over HTTPS from `download.freebsd.org` and each file is verified against the release `MANIFEST` before it is extracted. Archived releases are not served there and are not supported.

# Examples
## Build a regular 15.1-RELEASE image with a ZFS root
`build.sh -r 15.1 -f zfs`

## Build a DEBUG-enabled (root password set) image with a UFS root
`build.sh -d -f ufs`

# Download Images
Images are generated on the 15th of every month via GitHub Actions. They can be downloaded [here](http://freebsd-images.s3-website-us-east-1.amazonaws.com):
* [ZFS](https://freebsd-images.s3.us-east-1.amazonaws.com/artifacts/freebsd-zfs.tar.gz)
* [UFS](https://freebsd-images.s3.us-east-1.amazonaws.com/artifacts/freebsd-ufs.tar.gz)
* [SHA256SUMS](https://freebsd-images.s3.us-east-1.amazonaws.com/artifacts/SHA256SUMS)
* [ZFS attestation](https://freebsd-images.s3.us-east-1.amazonaws.com/artifacts/freebsd-zfs.tar.gz.sigstore.json)
* [UFS attestation](https://freebsd-images.s3.us-east-1.amazonaws.com/artifacts/freebsd-ufs.tar.gz.sigstore.json)

Verify a download with `sha256sum -c --ignore-missing SHA256SUMS` (GNU coreutils) or compare the output of `sha256 <file>` on FreeBSD with the entry in `SHA256SUMS`. The web page shows the checksum next to each download.

Each image has a GitHub build provenance attestation, published next to it as `<image>.sigstore.json`. Verify a download with the GitHub CLI and the bundle, so `gh` does not have to fetch the attestation from GitHub: `gh attestation verify freebsd-zfs.tar.gz --bundle freebsd-zfs.tar.gz.sigstore.json --repo cdf-eagles/freebsd-cloud-img`. Without `--bundle`, `gh` looks the attestation up in GitHub by the digest of the file. Add `--signer-workflow cdf-eagles/freebsd-cloud-img/.github/workflows/generate_image.yml` to require that this workflow built it.

# Continuous integration
`.github/workflows/ci.yml` runs on every pull request and push to `main`, weekly, and on demand. It scans the history of the checked-out commit with gitleaks (from a checksum-verified release, on a complete clone), then runs shellcheck, `scripts/check_cloudify.sh`, yamllint, and the pre-commit hooks, which include the workflow and Dependabot schemas, actionlint, ripsecrets, and `detect-private-key` (each tool runs once).

Every action is pinned to a commit, and every tool CI installs to an exact version. The runner image is pinned to Ubuntu 24.04, whose own packages are not. Tool versions live where Dependabot updates them weekly: the Python tools in `ci/requirements.txt`, and actionlint and the schema checks in `.pre-commit-config.yaml`. gitleaks is pinned with its checksum in the workflow, and the weekly run's **Tool drift** job opens an issue when it falls behind its latest release.

# Development
Gates before committing: `shellcheck scripts/*.sh`, `sh scripts/check_cloudify.sh`, `yamllint --strict .`, and `pre-commit run --all-files`. Run `pre-commit install` once per clone: it also installs a push hook that runs gitleaks over the commits being pushed, which needs `gitleaks` on the path.

# Publishing
A pull request that changes `scripts/build.sh` or `.github/workflows/generate_image.yml` builds both images without publishing them. A push to `main` that changes `scripts/build.sh`, the monthly schedule and a manual run build and publish the images, their attestation bundles and `SHA256SUMS` to the `artifacts/` prefix of the bucket, after attesting the images (the publish job alone has `id-token: write` and `attestations: write`). `publish_web.yml` publishes `web/` to the bucket root on a push to `main` that changes it, which includes a merged pull request, and on a manual run.

The publish jobs hold no static AWS keys. Each one requests a GitHub OpenID Connect (OIDC) token (`id-token: write` on that job only) and assumes an IAM role with `aws-actions/configure-aws-credentials`. The role trusts the GitHub OIDC provider for this repository's `main` branch only, so a pull request or a manual run from another branch cannot publish; its subject condition lists both `repo:cdf-eagles/freebsd-cloud-img:ref:refs/heads/main` and the immutable form with the owner and repository IDs.

Repository Actions secrets: `AWS_ROLE_ARN` (`arn:aws:iam::<account id>:role/<role name>`), `AWS_REGION` and `AWS_BUCKET`.

The role needs `s3:PutObject` and `s3:AbortMultipartUpload` on `arn:aws:s3:::<bucket>/*` and `s3:ListBucket` on `arn:aws:s3:::<bucket>`, granted by its own IAM policy; the bucket policy only allows public `s3:GetObject`.
