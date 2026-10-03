#!/bin/sh
#
# Syntax-check build.sh and the cloudify.sh it generates, for a normal and a
# debug build.
#
# Usage: check_cloudify.sh [path/to/build.sh]

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
build_script="${1:-${script_dir}/build.sh}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is not installed"

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

echo ">>> sh -n ${build_script}"
sh -n "${build_script}" || fail "${build_script} has a syntax error"

# Extract the block that writes cloudify.sh. Both markers must be present.
awk '
    /cat <<EOF_CLOUDIFY/ { started = 1 }
    /chmod \+x .*cloudify\.sh/ { if (started) { ended = 1 } }
    started && !ended { print }
    END { if (!started || !ended) exit 1 }
' "${build_script}" >"${workdir}/generate.sh" ||
    fail "could not find the cloudify.sh block in ${build_script}"

# The block calls sysctl, which does not exist outside FreeBSD.
mkdir "${workdir}/bin"
printf '#!/bin/sh\necho 1500000\n' >"${workdir}/bin/sysctl"
chmod +x "${workdir}/bin/sysctl"

for debug in 0 1; do
    mnt_dir="${workdir}/mnt${debug}"
    mkdir -p "${mnt_dir}/tmp"
    generated="${mnt_dir}/tmp/cloudify.sh"

    echo ">>> Generating cloudify.sh with DEBUG=${debug}"
    DEBUG="${debug}" abi_version=15 mnt_dir="${mnt_dir}" PATH="${workdir}/bin:${PATH}" \
        sh -eu "${workdir}/generate.sh" >/dev/null ||
        fail "the cloudify.sh block failed with DEBUG=${debug}"

    [ -s "${generated}" ] || fail "no cloudify.sh was written with DEBUG=${debug}"
    [ "$(head -n 1 "${generated}")" = "#!/bin/sh" ] ||
        fail "cloudify.sh does not start with #!/bin/sh with DEBUG=${debug}"
    [ "$(tail -n 1 "${generated}")" = "exit 0" ] ||
        fail "cloudify.sh does not end with exit 0 with DEBUG=${debug}"

    echo ">>> sh -n cloudify.sh (DEBUG=${debug})"
    sh -n "${generated}" ||
        fail "the generated cloudify.sh has a syntax error with DEBUG=${debug}"

    echo ">>> shellcheck cloudify.sh (DEBUG=${debug})"
    shellcheck --shell=sh "${generated}" ||
        fail "shellcheck found problems in the generated cloudify.sh with DEBUG=${debug}"
done

echo ">>> OK"
