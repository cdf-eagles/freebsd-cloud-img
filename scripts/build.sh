#!/bin/sh
#
# Original code from https://github.com/virt-lightning/freebsd-cloud-images
#
# Modified to support FreeBSD 15.0-RELEASE and forward. (UNOFFICIAL)
#
# This script will generate a RAW image file using a FreeBSD 15.x host to be used with bhyve or
# other virtualization platforms that can work with cloud-init.
#
# Images currently only tested on bhyve on FreeBSD 15.0-RELEASE
#
# Written/Updated by Christopher Fernando
# https://github.com/cdf-eagles/freebsd-cloud-img
#

MAJOR="1"
MINOR="0"
PATCH="1"

# for getopts
cmdopts="dvhr:f:"

# defaults
# shellcheck disable=SC3040 # pipefail exists in FreeBSD sh
set -euo pipefail
DEBUG=${DEBUG:-0}
RELEASE=${RELEASE:-15.0}
ROOT_FS=${ROOTFS:-zfs}
FS_TYPES="zfs ufs"
TAROPTS=""

# usage() - print usage/command line options information
#
usage() {
    cmdname=$(basename "$0")
    echo "Usage: $cmdname [-d] [-v] [-r <FreeBSD Release>] [-f <root fstype>]"
    echo "  -d,    Enable debug mode for script AND image (sets a root password in the image).    EnvVar:DEBUG "
    echo "  -r,    FreeBSD Release to download. [Default: 15.0]                                   EnvVar:RELEASE"
    echo "  -f,    Root filesystem type (zfs or ufs). [Default: zfs]                              EnvVar:ROOT_FS"
    echo "  -v,    Script version information."
    echo "  -h,    Display usage/help."
}

# enable_debug() - set debugging output options/etc.
#
enable_debug() {
    # shellcheck disable=SC3040 # pipefail exists in FreeBSD sh
    set -euxo pipefail
    TAROPTS="v"
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

    BASE_URL="http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${fbsd_release}-RELEASE"
    ISO_DATE=$(date '+%Y-%m-%d')

    # used in pkg configuration
    abi_version=$(echo "$fbsd_release" | sed 's/\..*$//')

    # image file options
    image_file="freebsd-${fbsd_release}-${root_fs}-${ISO_DATE}.raw"
    image_bs_count="3000"
    image_blocksize="1148576"  # ( image_blocksize * image_bs_count ) / (1024 ^ 3) = Size in GB

    # image root zpool name
    zfs_poolname="zfsroot"

    # temporary mount point for configuring image
    mnt_dir="/mnt"

    # cloud-init configuration direction within the image
    cloud_dir="${mnt_dir}/usr/local/etc/cloud"

    echo ">>> Checking FreeBSD-${fbsd_release}-RELEASE base URL"
    if ! fetch -o /dev/null -q "$BASE_URL"; then
        BASE_URL="http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/amd64/${fbsd_release}-RELEASE"
    fi

    if [ "${root_fs}" = "zfs" ]; then
        echo ">>> Configuring for ZFS root"
        gptboot="/boot/gptzfsboot"
    else
        echo ">>> Configuring for UFS root"
        gptboot="/boot/gptboot"
    fi

    echo ">>> Creating RAW image file bs=${image_blocksize} count=${image_bs_count}"
    dd if=/dev/zero of="${image_file}" bs="${image_blocksize}" count="${image_bs_count}" || return 1

    echo ">>> Creating memory device from ${image_file}"
    md_dev=$(mdconfig -a -t vnode -f "${image_file}")

    echo ">>> Create GPT partitioning scheme"
    gpart create -s gpt "${md_dev}"

    echo ">>>> Adding freebsd-boot partition (p1)"
    gpart add -t freebsd-boot -s 1024 "${md_dev}"

    echo ">>>> Adding bootcode to boot partition"
    gpart bootcode -b /boot/pmbr -p "${gptboot}" -i 1 "${md_dev}"

    echo ">>>> Adding EFI partition (p2)"
    gpart add -t efi -s 128M "${md_dev}"

    echo ">>>> Adding freebsd-${root_fs} partition (p3)"
    gpart add -t freebsd-"${root_fs}" -l rootfs "${md_dev}"

    echo ">>>> UFS format EFI partition"
    newfs_msdos -F 32 -c 1 /dev/"${md_dev}"p2

    echo ">>>> Mount EFI partition (msdosfs) on ${mnt_dir}"
    mount -t msdosfs /dev/"${md_dev}"p2 "${mnt_dir}"

    echo ">>>> Create EFI boot directories"
    mkdir -p "${mnt_dir}"/EFI/BOOT

    echo ">>>> Copy EFI boot loader to EFI boot directory"
    cp /boot/loader.efi "${mnt_dir}"/EFI/BOOT/BOOTX64.efi || return 1

    echo ">>>> Unmount ${mnt_dir}"
    umount "${mnt_dir}" || return 1

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

    for fbsd_pkg in base kernel
    do
        echo ">>> Fetching and extracting ${fbsd_pkg}.txz installation package..."
        fetch -o - "${BASE_URL}/${fbsd_pkg}.txz" | tar "${TAROPTS}xf" - -C "${mnt_dir}"
    done

    echo ">>> Creating custom script (cloudify.sh) to bootstrap cloud-init"
    cat <<EOF_CLOUDIFY >"${mnt_dir}"/tmp/cloudify.sh
#!/bin/sh
#

# needed for pkg operations
export ABI="FreeBSD:${abi_version}:amd64"

# where pkg configuration is located
export ETCDIR="/usr/local/etc"

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

# create pkg.conf
echo ">>>> Create pkg.conf"
mkdir -p "\$ETCDIR" && chmod -R go+rX "\$ETCDIR"
cat <<EOF_PKGCONF >>"\${ETCDIR}"/pkg.conf
ABI = "\$ABI";
EOF_PKGCONF
ls -l "\${ETCDIR}"/pkg.conf
echo "====>>>> \${ETCDIR}/pkg.conf <<<<===="
echo "****"
cat "\${ETCDIR}"/pkg.conf
echo "****"

# create pkg repository configuration
echo ">>>> Create pkg FreeBSD.conf"
mkdir -p "\${ETCDIR}"/pkg/repos || echo "Unable to create \${ETCDIR}/pkg/repos"
ls -ld "\${ETCDIR}"/pkg/repos

cat <<EOF_PKGREPOCONF >"\${ETCDIR}"/pkg/repos/FreeBSD.conf
FreeBSD: {
  mirror_type: "none",
  url: "http://pkg.FreeBSD.org/\${ABI}/latest",
}
EOF_PKGREPOCONF
ls -l "\${ETCDIR}"/pkg/repos/FreeBSD.conf
echo "====>>>> \${ETCDIR}/pkg/repos/FreeBSD.conf <<<<===="
echo "****"
cat "\${ETCDIR}"/pkg/repos/FreeBSD.conf
echo "****"

# bootstrap pkg and install cloud-init and dependencies
echo ">>>> Bootstraping pkg"
pkg bootstrap -f -y
echo ">>>> Updating pkg repository"
pkg update
echo ">>>> Installing packages, including cloud-init"
pkg install -y ca_root_nss python3 qemu-guest-agent py311-cloud-init
touch /etc/rc.conf

# clean up pkg configuration
rm -rf "\${ETCDIR}\"/pkg "\${ETCDIR}\"/pkg.conf

exit 0
EOF_CLOUDIFY

    if [ "$DEBUG" -eq "1" ]; then  # Lock root account unless DEBUG enabled
        # Generate a root password
        ROOTPW=$(openssl rand -base64 16 | sed 's/..$//')
        echo "echo '${ROOTPW}' | pw usermod -n root -h 0" >> ${mnt_dir}/tmp/cloudify.sh
        echo ">>> DEBUG: root password is set to '$ROOTPW'"
    else
        echo "pw mod user root -w no" >> ${mnt_dir}/tmp/cloudify.sh
    fi

    chmod +x "${mnt_dir}"/tmp/cloudify.sh

    cp /etc/resolv.conf "${mnt_dir}"/etc/resolv.conf

    mount -t devfs devfs "${mnt_dir}"/dev || return 1

    # Run freebsd-update using the "-b" option to apply the latest patches to the chroot environment
    echo ">>> Performing freebsd-update for ${root_fs} image on ${mnt_dir}."
    export ASSUME_ALWAYS_YES=YES
    export PAGER="cat"
    export LESS='-F -R'
    freebsd-update -b "${mnt_dir}" --currently-running "${fbsd_release}"-RELEASE fetch --not-running-from-cron
    freebsd-update -b "${mnt_dir}" --currently-running "${fbsd_release}"-RELEASE install
    unset ASSUME_ALWAYS_YES PAGER LESS

    echo ">>> Executing script to bootstrap cloud-init within image"
    chroot "${mnt_dir}" /tmp/cloudify.sh

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
