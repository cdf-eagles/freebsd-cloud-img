[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)
[![main](https://img.shields.io/badge/main-stable-green.svg?maxAge=2592000)]('')
[![Build FreeBSD Cloud Images](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/generate_image.yml/badge.svg)](https://github.com/cdf-eagles/freebsd-cloud-img/actions/workflows/generate_image.yml)

# FreeBSD Cloud-Image (bhyve)
This is a script/repository for generating an UNOFFICIAL FreeBSD cloud-init enabled image for use with bhyve. These images may also work with OpenStack and/or NoCloud environments.

Original code was taken from [Virt-Lightning](https://github.com/virt-lightning/freebsd-cloud-images).

# Usage
```
Usage: build.sh [-d] [-v] [-r <FreeBSD Release>] [-f <root fstype>]
  -d,    Enable debug mode for script AND image (sets a root password in the image).    EnvVar:DEBUG
  -r,    FreeBSD Release to download. [Default: 15.0]                                   EnvVar:RELEASE
  -f,    Root filesystem type (zfs or ufs). [Default: zfs]                              EnvVar:ROOT_FS
  -v,    Script version information.
  -h,    Display usage.
```

# Examples
## Build a regular 15.0-RELEASE image with a ZFS root
`build.sh -r 15.0 -f zfs`

## Build a DEBUG-enabled (root password set) image with a UFS root
`build.sh -d -f ufs`

# Download Images
Images are generated on the 15th of every month via GitHub Actions. They can be downloaded here:
* [ZFS](https://d14vrbqi5qyyq7.cloudfront.net/artifacts/freebsd-zfs.tar.gz)
* [UFS](https://d14vrbqi5qyyq7.cloudfront.net/artifacts/freebsd-ufs.tar.gz)
