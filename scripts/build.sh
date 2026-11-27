#!/bin/sh
#
# Original code from https://github.com/virt-lightning/freebsd-cloud-images
#
# Modified to support FreeBSD 15.0-RELEASE and forward. (UNOFFICIAL)
#
# This script will generate a RAW image file using a FreeBSD 15.x host to be used with bhyve or
# other virtualization platforms that can work with cloud-init.
#
# The base system is installed from FreeBSD's packaged base (the FreeBSD-base repository), as
# FreeBSD's own VM images are, and is patched afterwards with pkg, not freebsd-update.
#
# Images currently only tested on bhyve on FreeBSD 15.1-RELEASE
#
# Written/Updated by Christopher Fernando
# https://github.com/cdf-eagles/freebsd-cloud-img
#

MAJOR="2"
MINOR="0"
PATCH="0"

# for getopts
cmdopts="dvhr:f:"

# defaults
# shellcheck disable=SC3040 # pipefail exists in FreeBSD sh
set -euo pipefail
DEBUG=${DEBUG:-0}
RELEASE=${RELEASE:-15.1}
ROOT_FS=${ROOT_FS:-zfs}
FS_TYPES="zfs ufs"

# usage() - print usage/command line options information
#
usage() {
    cmdname=$(basename "$0")
    echo "Usage: $cmdname [-d] [-v] [-r <FreeBSD Release>] [-f <root fstype>]"
    echo "  -d,    Enable debug mode for script AND image (sets a root password in the image).    EnvVar:DEBUG "
    echo "  -r,    FreeBSD Release to download. [Default: 15.1]                                   EnvVar:RELEASE"
    echo "  -f,    Root filesystem type (zfs or ufs). [Default: zfs]                              EnvVar:ROOT_FS"
    echo "  -v,    Script version information."
    echo "  -h,    Display usage/help."
}

# enable_debug() - set debugging output options/etc.
#
enable_debug() {
    # shellcheck disable=SC3040 # pipefail exists in FreeBSD sh
    set -euxo pipefail
    DEBUG=1
}

# version() - print script version
#
version() {
    scriptname=$(basename "$0")
    echo "${scriptname}: v${MAJOR}.${MINOR}.${PATCH}"
}

while getopts "$cmdopts" flag; do
    case "${flag}" in
        d) enable_debug ;;
        v) version; exit 0 ;;
        h) usage; exit 0 ;;
        r) RELEASE=${OPTARG:-15.0} ;;
        f) ROOT_FS=${OPTARG:-zfs} ;;
        \?) echo "ERROR: Unknown option -$OPTARG" >&2; usage ; exit 1 ;;
        *) usage; exit 1 ;;
    esac
done

# Check and set in case environment variable was used instead of cmdline option
if [ "$DEBUG" -eq 1 ]; then
    enable_debug
fi

# check_eol() - stop when a release has passed its end-of-life date
#
# Inputs: $1 = FreeBSD release in MAJOR.MINOR format (e.g. 15.1)
#
# Outputs: Returns 1 if endoflife.date says the release is end-of-life, 0 otherwise. A lookup that
#          fails or cannot be read prints a warning and returns 0, so an outage of the lookup does
#          not stop a build.
#
check_eol() {
    eol_url="https://endoflife.date/api/v1/products/freebsd/releases/$1"
    eol_json=$(fetch -q -o - "${eol_url}" 2>/dev/null) || eol_json=""
    if printf '%s' "${eol_json}" | grep -Eq '"isEol"[[:space:]]*:[[:space:]]*true'; then
        echo "ERROR: FreeBSD $1-RELEASE has passed its end-of-life date (${eol_url})." >&2
        echo "ERROR: Build a supported release (https://www.freebsd.org/security/#sup): change the RELEASE default in" >&2
        echo "ERROR: scripts/build.sh (or pass -r) and the release of the build VM in .github/workflows/generate_image.yml." >&2
        return 1
    fi
    if ! printf '%s' "${eol_json}" | grep -Eq '"isEol"[[:space:]]*:[[:space:]]*false'; then
        echo "WARNING: could not read the end-of-life status of FreeBSD $1 from ${eol_url}; continuing." >&2
    fi
    return 0
}

# repo_field() - print one field of one repository from `pkg -vv` output read on stdin
#
# Inputs: $1 = repository name (e.g. FreeBSD-base)
#         $2 = field name (e.g. url, enabled)
#
# Outputs: Prints the value without quotes or the trailing comma, or nothing if it is not listed.
#
repo_field() {
    awk -v start="  $1: {" -v key="$2" '
        index($0, start) == 1 { inside = 1; next }
        inside && /^  [^ ]/ { inside = 0 }
        inside {
            colon = index($0, ":")
            if (colon == 0) next
            name = substr($0, 1, colon - 1)
            gsub(/[[:space:]]/, "", name)
            if (name != key) next
            value = substr($0, colon + 1)
            gsub(/^[[:space:]]+|[[:space:],]+$/, "", value)
            gsub(/"/, "", value)
            print value
            exit
        }'
}

# verify_image() - check the installed image before it is closed
#
# Inputs: $1 = mount point of the image root
#         $2 = the base sets the image was built with (space separated)
#
# Outputs: Returns 0 if every check passes, 1 at the first failure.
#
verify_image() {
    vroot=$1
    want_sets=$(echo "$2" | tr ' ' '\n' | grep '^FreeBSD-set-' | sort)

    echo ">>> Checking that pkg owns the base system"
    chroot "${vroot}" pkg which -q /usr/bin/uname >/dev/null || { echo "ERROR: pkg does not own /usr/bin/uname" >&2; return 1; }

    echo ">>> Checking the installed base sets"
    have_sets=$(chroot "${vroot}" pkg query -e '%a = 0' '%n' | grep '^FreeBSD-set-' | sort)
    if [ "${have_sets}" != "${want_sets}" ]; then
        echo "ERROR: the explicitly installed base sets are not the expected ones" >&2
        printf 'expected:\n%s\ninstalled:\n%s\n' "${want_sets}" "${have_sets}" >&2
        return 1
    fi

    echo ">>> Checking the image's pkg repository configuration"
    repo_conf="${vroot}/usr/local/etc/pkg/repos/FreeBSD.conf"
    if [ "$(cat "${repo_conf}")" != "FreeBSD-base: { enabled: yes }" ]; then
        echo "ERROR: ${repo_conf} is not exactly 'FreeBSD-base: { enabled: yes }'" >&2
        return 1
    fi
    # The pkg package creates /usr/local/etc/pkg.conf from pkg.conf.sample (@sample), as on FreeBSD's
    # own images; the build must not have added to it (an ABI pin, for example).
    pkg_conf="${vroot}/usr/local/etc/pkg.conf"
    if [ -e "${pkg_conf}" ] && ! cmp -s "${pkg_conf}" "${pkg_conf}.sample"; then
        echo "ERROR: ${pkg_conf} differs from pkg.conf.sample" >&2
        return 1
    fi
    pkg_vv=$(chroot "${vroot}" pkg -vv) || { echo "ERROR: pkg -vv failed in the image" >&2; return 1; }
    base_url=$(printf '%s\n' "${pkg_vv}" | repo_field FreeBSD-base url)
    base_enabled=$(printf '%s\n' "${pkg_vv}" | repo_field FreeBSD-base enabled)
    ports_url=$(printf '%s\n' "${pkg_vv}" | repo_field FreeBSD-ports url)
    echo "FreeBSD-base: url=${base_url} enabled=${base_enabled}; FreeBSD-ports: url=${ports_url}"
    case "${base_url}" in
        pkg+https://*/base_release_[0-9]*) ;;
        *) echo "ERROR: FreeBSD-base does not resolve to a base_release repository over pkg+https" >&2; return 1 ;;
    esac
    [ "${base_enabled}" = "yes" ] || { echo "ERROR: FreeBSD-base is not enabled in the image" >&2; return 1; }
    case "${ports_url}" in
        pkg+https://*/quarterly) ;;
        *) echo "ERROR: FreeBSD-ports does not resolve to the quarterly branch over pkg+https" >&2; return 1 ;;
    esac

    echo ">>> Checking that freebsd-update left nothing in the image"
    if [ -d "${vroot}/var/db/freebsd-update" ] && [ -n "$(ls -A "${vroot}/var/db/freebsd-update")" ]; then
        echo "ERROR: ${vroot}/var/db/freebsd-update is not empty" >&2
        return 1
    fi
    return 0
}

# build() - main operations
#
# Inputs: $1 = FreeBSD release to download in MAJOR.MINOR format (e.g. 15.0)
#         $2 = Root filesystem type. One of 'ufs' or 'zfs'.
#
# Outputs: Returns 0 if build suceeds, 1 if not.
#
build() {
    fbsd_release=$1
    root_fs=$2

    fs_check=$(echo "${FS_TYPES}" | grep -c "${root_fs}")
    if [ "${fs_check}" -eq "0" ]; then echo "ERROR: '${root_fs}' is not one of '${FS_TYPES}'"; return 1; fi

    ISO_DATE=$(date '+%Y-%m-%d')

    if ! check_eol "${fbsd_release}"; then return 1; fi

    # used in pkg configuration
    abi_version=$(echo "$fbsd_release" | sed 's/\..*$//')
    minor_version=$(echo "$fbsd_release" | sed 's/^[^.]*\.//')

    # The packages FreeBSD's own VM images install on amd64 (release/tools/vmimage.subr,
    # vm_base_packages_list): the full base system, the kernels, the 32-bit libraries, the test
    # suite, their debug sets, and pkg itself.
    base_packages="FreeBSD-set-base FreeBSD-set-base-dbg FreeBSD-set-kernels FreeBSD-set-kernels-dbg"
    base_packages="${base_packages} FreeBSD-set-lib32 FreeBSD-set-lib32-dbg FreeBSD-set-tests pkg"

    # pkg reads fingerprint paths relative to --rootdir, so the build host's keys are copied into
    # the image before the install, as bsdinstall's packaged-base installer does.
    pkgbase_keys="/usr/share/keys/pkgbase-${abi_version}"
    if [ ! -d "${pkgbase_keys}" ]; then
        echo "ERROR: ${pkgbase_keys} is missing on the build host; build on FreeBSD ${abi_version}.x." >&2
        return 1
    fi

    # image file options
    image_file="freebsd-${fbsd_release}-${root_fs}-${ISO_DATE}.raw"
    image_size="5g"  # the size of FreeBSD's own cloud-init image (release/tools/basic-cloudinit.conf, VMSIZE)

    # image root zpool name
    zfs_poolname="zfsroot"

    # temporary mount point for configuring image
    mnt_dir="/mnt"

    # cloud-init configuration direction within the image
    cloud_dir="${mnt_dir}/usr/local/etc/cloud"

    if [ "${root_fs}" = "zfs" ]; then
        echo ">>> Configuring for ZFS root"
        gptboot="/boot/gptzfsboot"
    else
        echo ">>> Configuring for UFS root"
        gptboot="/boot/gptboot"
    fi

    echo ">>> Creating sparse RAW image file of ${image_size}"
    rm -f "${image_file}"
    truncate -s "${image_size}" "${image_file}" || return 1

    echo ">>> Creating memory device from ${image_file}"
    md_dev=$(mdconfig -a -t vnode -f "${image_file}")

    echo ">>> Create GPT partitioning scheme"
    gpart create -s gpt "${md_dev}"

    echo ">>>> Adding freebsd-boot partition (p1)"
    gpart add -t freebsd-boot -s 1024 "${md_dev}"

    echo ">>>> Adding EFI partition (p2)"
    gpart add -t efi -s 128M "${md_dev}"

    echo ">>>> Adding freebsd-${root_fs} partition (p3)"
    gpart add -t freebsd-"${root_fs}" -l rootfs "${md_dev}"

    echo ">>>> FAT32 format EFI partition"
    newfs_msdos -F 32 -c 1 /dev/"${md_dev}"p2

    if [ "${root_fs}" = "zfs" ]; then
        echo ">>> Creating '${zfs_poolname}' ZPOOL"
        zpool create -o altroot=/mnt                     "${zfs_poolname}" "${md_dev}"p3
        zfs set compress=on                              "${zfs_poolname}"
        zfs create -o mountpoint=none                    "${zfs_poolname}"/ROOT
        zfs create -o mountpoint=/ -o canmount=noauto    "${zfs_poolname}"/ROOT/default

        echo ">>> Mounting '${zfs_poolname}' ZPOOL on '${mnt_dir}'"
        mount -t zfs "${zfs_poolname}"/ROOT/default "${mnt_dir}" || return 1
        zpool set bootfs="${zfs_poolname}"/ROOT/default "${zfs_poolname}" || return 1
    else
        echo ">>> Creating UFS root"
        newfs -U -L FreeBSD /dev/"${md_dev}"p3
        tunefs -p /dev/"${md_dev}"p3
        echo ">>> Mounting '/dev/${md_dev}p3' UFS on '${mnt_dir}'"
        mount /dev/"${md_dev}"p3 "${mnt_dir}" || return 1
    fi

    echo ">>> Installing the FreeBSD ${fbsd_release} base system from the FreeBSD-base repository"
    mkdir -p "${mnt_dir}/usr/share/keys"
    cp -R /usr/share/keys/* "${mnt_dir}/usr/share/keys/" || return 1
    repo_dir=$(mktemp -d "${TMPDIR:-/tmp}/freebsd-base-repo.XXXXXX")
    # The values of FreeBSD's own FreeBSD-base stanza for a release (/etc/pkg/FreeBSD.conf), with
    # the minor release named, so the build installs the release asked for, not the build host's.
    cat <<EOF_BASEREPO >"${repo_dir}/FreeBSD-base.conf"
FreeBSD-base: {
  url: "pkg+https://pkg.FreeBSD.org/\${ABI}/base_release_${minor_version}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkgbase-${abi_version}",
  enabled: yes
}
EOF_BASEREPO
    pkg_base() {
        pkg --rootdir "${mnt_dir}" --repo-conf-dir "${repo_dir}" \
            -o ASSUME_ALWAYS_YES=yes -o IGNORE_OSVERSION=yes -o ABI="FreeBSD:${abi_version}:amd64" "$@"
    }
    # shellcheck disable=SC2086 # base_packages is a list of package names
    if ! pkg_base update -r FreeBSD-base || ! pkg_base install -U -r FreeBSD-base ${base_packages}; then
        rm -rf "${repo_dir}"
        echo "ERROR: unable to install the base system from the FreeBSD-base repository (base_release_${minor_version})." >&2
        return 1
    fi
    rm -rf "${repo_dir}"

    echo ">>> Enabling the FreeBSD-base repository in the image, as FreeBSD's own images do"
    mkdir -p "${mnt_dir}/usr/local/etc/pkg/repos"
    echo 'FreeBSD-base: { enabled: yes }' > "${mnt_dir}/usr/local/etc/pkg/repos/FreeBSD.conf"

    echo ">>> Marking the first boot, so firstboot rc.d scripts such as firstboot_pkg_upgrade run once"
    touch "${mnt_dir}/firstboot"

    echo ">>>> Adding the image's own bootcode to the boot partition"
    gpart bootcode -b "${mnt_dir}/boot/pmbr" -p "${mnt_dir}${gptboot}" -i 1 "${md_dev}" || return 1

    echo ">>>> Copying the image's own EFI loader to the EFI partition"
    esp_dir=$(mktemp -d "${TMPDIR:-/tmp}/freebsd-esp.XXXXXX")
    mount -t msdosfs /dev/"${md_dev}"p2 "${esp_dir}" || return 1
    mkdir -p "${esp_dir}"/EFI/BOOT
    if ! cp "${mnt_dir}"/boot/loader.efi "${esp_dir}"/EFI/BOOT/BOOTX64.efi; then
        umount "${esp_dir}"
        return 1
    fi
    umount "${esp_dir}" || return 1
    rmdir "${esp_dir}"

    echo ">>> Creating custom script (cloudify.sh) to bootstrap cloud-init"
    # shellcheck disable=SC2006 # C-Shell does not have $() syntax
    cat <<EOF_CLOUDIFY >"${mnt_dir}"/tmp/cloudify.sh
#!/bin/sh
#

# needed for pkg operations
export ABI="FreeBSD:${abi_version}:amd64"
export OSVERSION=$(sysctl -n kern.osreldate)

# display environment variables
echo "====>>>> \$0 env <<<<===="
echo "****"
env | sort -n
echo "****"

# display filesystem information
echo ">>>> Disk Information"
echo "****"
df
echo "****"
gpart show
echo "****"

# ensure OSVERSION is set globally for the system
echo ">>>> Create /etc/profile.d/OSVERSION.sh"
cat <<EOF_OSVERSION > /etc/profile.d/OSVERSION.sh
export OSVERSION=$(sysctl -n kern.osreldate)
EOF_OSVERSION
chmod 444 /etc/profile.d/OSVERSION.sh
echo ">>>> Configure OSVERSION for C-Shell"
echo 'setenv OSVERSION `sysctl -n kern.osreldate`' >> /etc/csh.cshrc

# The image keeps FreeBSD's own pkg configuration: /etc/pkg/FreeBSD.conf (ports on the quarterly
# branch) plus FreeBSD-base enabled; pkg itself came from FreeBSD-base with the base system.
echo ">>>> Checking that pkg is installed"
pkg -N || { echo "ERROR: pkg is not installed in the image"; exit 1; }
echo ">>>> Checking that pkg uses only signed HTTPS repositories"
pkg -vv >/dev/null || { echo "ERROR: pkg -vv failed"; exit 1; }
if pkg -vv | grep -Eiq 'signature_type[[:space:]]*:[[:space:]]*"NONE"|url[[:space:]]*:[[:space:]]*"http://'; then
    echo "ERROR: pkg resolves to an unsigned or plain HTTP repository"
    pkg -vv
    exit 1
fi
pkg -vv | grep -Eiq 'signature_type[[:space:]]*:[[:space:]]*"FINGERPRINTS"' || { echo "ERROR: no repository with fingerprint signatures is enabled"; pkg -vv; exit 1; }
echo ">>>> Updating pkg repository"
pkg update
echo ">>>> Installing packages, including cloud-init"
pkg install -y ca_root_nss python3 qemu-guest-agent firstboot-pkg-upgrade || { echo "ERROR: unable to install ca_root_nss, python3, qemu-guest-agent and firstboot-pkg-upgrade"; exit 1; }

# derive the Python flavor (e.g. py312) from the installed python3
PYFLAVOR=\$(/usr/local/bin/python3 -c 'import sys; print("py%d%d" % sys.version_info[:2])') || { echo "ERROR: unable to determine the installed Python version"; exit 1; }
echo ">>>> Installing \${PYFLAVOR}-cloud-init"
pkg install -y "\${PYFLAVOR}-cloud-init" || { echo "ERROR: unable to install \${PYFLAVOR}-cloud-init"; exit 1; }

for pkgname in ca_root_nss python3 qemu-guest-agent firstboot-pkg-upgrade "\${PYFLAVOR}-cloud-init"; do
    pkg info -e "\${pkgname}" || { echo "ERROR: \${pkgname} is not installed in the image"; exit 1; }
done
touch /etc/rc.conf

# set timezone to UTC by default
tzsetup UTC
echo "==== DEFAULT TIMEZONE ===="
cat /var/db/zoneinfo
EOF_CLOUDIFY

    if [ "$DEBUG" -eq "1" ]; then  # Lock root account unless DEBUG enabled
        # Generate a root password
        ROOTPW=$(openssl rand -base64 16 | sed 's/..$//')
        echo "echo '${ROOTPW}' | pw usermod -n root -h 0 || exit 1" >> ${mnt_dir}/tmp/cloudify.sh
        echo ">>> DEBUG: root password is set to '$ROOTPW'"
    else
        {
            echo "pw usermod -n root -w no || exit 1"
            echo "grep -q '^root:[*]:' /etc/master.passwd || { echo 'ERROR: root account is not locked'; exit 1; }"
            echo "echo '>>>> Root account is locked'"
        } >> ${mnt_dir}/tmp/cloudify.sh
    fi
    echo "exit 0" >> ${mnt_dir}/tmp/cloudify.sh

    chmod +x "${mnt_dir}"/tmp/cloudify.sh

    cp /etc/resolv.conf "${mnt_dir}"/etc/resolv.conf

    mount -t devfs devfs "${mnt_dir}"/dev || return 1

    echo ">>> Executing script to bootstrap cloud-init within image"
    chroot "${mnt_dir}" /tmp/cloudify.sh

    if ! verify_image "${mnt_dir}" "${base_packages}"; then return 1; fi

    echo ">>> Clean up custom script artifacts"
    umount -f "${mnt_dir}"/dev

    rm -f "${mnt_dir}"/tmp/cloudify.sh

    # zero out resolv.conf within the image (dhcp/cloud-init/etc. to configure on first boot)
    cp /dev/null "${mnt_dir}"/etc/resolv.conf

    echo ">>> Create /etc/fstab for UFS (empty file for ZFS)"
    if [ "${root_fs}" = "ufs" ]; then
        echo '/dev/gpt/rootfs   /       ufs     rw      1       1' >> "${mnt_dir}"/etc/fstab
    else
        touch "${mnt_dir}"/etc/fstab
        chown root:wheel "${mnt_dir}"/etc/fstab && chmod 644 "${mnt_dir}"/etc/fstab
    fi

    echo ">>> Add /boot/loader.conf configuration"
    cat <<EOF_LOADERCONF >>"${mnt_dir}"/boot/loader.conf
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
autoboot_delay="-1"
console="comconsole,efi"
beastie_disable="YES"
virtio_p9fs_load="YES"
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gpt.enable="1"
kern.geom.label.gptid.enable="0"
EOF_LOADERCONF

    echo ">>> Enable serial console in /boot.config"
    echo '-P' >> "${mnt_dir}"/boot.config

    echo ">>> Clean out target image /tmp directory"
    rm -rf "${mnt_dir}"/tmp/*

    echo ">>> Add /etc/rc.conf configuration"
    cat <<EOF_RCCONF >>"${mnt_dir}"/etc/rc.conf
clear_tmp_enable="YES"
sshd_enable="YES"
sendmail_enable="NONE"
cloudinit_enable="YES"
ifconfig_DEFAULT="DHCP"
synchronous_dhclient="NO"
qemu_guest_agent_enable="YES"
qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"
firstboot_pkg_upgrade_enable="YES"
firstboot_pkg_upgrade_repos="FreeBSD-base"
EOF_RCCONF

    # ensure ZFS boot configuration is enabled and the filesystem is grown to specified disk size
    if [ "${root_fs}" = "zfs" ]; then
        echo ">>> Add ZFS loading to /boot/loader.conf and /etc/rc.conf"
        cat <<EOF_ZFSLOADER >>"${mnt_dir}"/boot/loader.conf
zfs_load="YES"
vfs.root.mountfrom="zfs:${zfs_poolname}/ROOT/default"
EOF_ZFSLOADER

        echo 'zfs_enable="YES"' >>"${mnt_dir}"/etc/rc.conf

        # make sure the directory exists before creating cloud.cfg
        if [ ! -e $cloud_dir ]; then
            echo ">>> Creading ${cloud_dir} configuration directory"
            mkdir -p "${cloud_dir}"
        fi

        cat <<EOF_ZFSGROW >>"${cloud_dir}"/cloud.cfg
growpart:
   mode: auto
   devices:
      - /dev/vtbd0p3
      - /
EOF_ZFSGROW
    fi # end ZFS autoresize configuration

    echo "===>>> IMAGE /etc/rc.conf <<<==="
    echo "***"
    cat "${mnt_dir}"/etc/rc.conf
    echo "***"
    echo "===>>> IMAGE /boot/loader.conf <<<==="
    echo "***"
    cat "${mnt_dir}"/boot/loader.conf
    echo "***"

    if [ "${root_fs}" = "zfs" ]; then
        echo ">>> Exporting ${zfs_poolname} ZPOOL"
        if [ "$DEBUG" -eq "1" ]; then
            ls "${mnt_dir}"
            ls "${mnt_dir}"/sbin
            ls "${mnt_dir}"/sbin/init
        fi
        zpool export "${zfs_poolname}"
    else
        echo ">>> Unmounting UFS root"
        umount /dev/"${md_dev}"p3
    fi

    echo ">>> Cleaning up memory disk"
    mdconfig -du "${md_dev}"

    echo ">>> Generating image file data..."
    hash=$(sha256sum "$image_file")
    imagesize=$(du -sh "$image_file")
    echo ">>> Image size  : $imagesize"
    echo ">>> SHA256      : $hash"

    if [ "$DEBUG" -eq "1" ]; then
        echo ">>> DEBUG: Image root password: ${ROOTPW}"
    fi

    return 0
}

# build image
build "$RELEASE" "$ROOT_FS"

exit "$?"
