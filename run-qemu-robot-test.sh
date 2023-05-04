#!/bin/bash -xe
###############################################################################
# 用来启动qemu运行images并使用robot对其进行持续集成（Continuous Integration，CI）测试的脚本
# This script is for starting QEMU against the input build and running the
# robot CI test suite against it.(ROBOT CI TEST CURRENTLY WIP)
#
###############################################################################
#
# Parameters used by the script:
#  UPSTREAM_WORKSPACE = The directory from which the QEMU components are being
#                       imported from. Generally, this is the build directory
#                       that is generated by the OpenBMC build-setup.sh script
#                       when run with "target=qemuarm".
#                       Example: /home/builder/workspace/openbmc-build/build.
# 
#
# Optional Variables:
#
#  WORKSPACE          = Path of the workspace directory where some intermediate
#                       files will be saved to.
#  QEMU_RUN_TIMER     = Defaults to 300, a timer for the QEMU container.
#  QEMU_LOGIN_TIMER   = Defaults to 180, a timer for the QEMU container to reach
#                       login.
#  DOCKER_IMG_NAME    = Defaults to openbmc/ubuntu-robot-qemu, the name the
#                       Docker image will be tagged with when built.
#  OBMC_BUILD_DIR     = Defaults to /tmp/openbmc/build, the path to the
#                       directory where the UPSTREAM_WORKSPACE build files will
#                       be mounted to. Since the build containers have been
#                       changed to use /tmp as the parent directory for their
#                       builds, move the mounting location to be the same to
#                       resolve issues with file links or referrals to exact
#                       paths in the original build directory. If the build
#                       directory was changed in the build-setup.sh run, this
#                       variable should also be changed. Otherwise, the default
#                       should be used.
#  LAUNCH             = Used to determine how to launch the qemu robot test
#                       containers. The options are "local", and "k8s". It will
#                       default to local which will launch a single container
#                       to do the runs. If specified k8s will launch a group of
#                       containers into a kubernetes cluster using the helper
#                       script.
#  QEMU_BIN           = Location of qemu-system-arm binary to use when starting
#                       QEMU relative to upstream workspace.  Default is
#                       ./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm
#                       which is the default location when doing a bitbake
#                       of obmc-phosphor-image. If you don't find the sysroots
#                       folder, run `bitbake build-sysroots`.
#
#  MACHINE            = Machine to run test against. The options are "witherspoon",
#                       "palmetto", "romulus", or undefined (default).  Default
#                       will use the versatilepb model.
#
#  DEFAULT_IMAGE_LOC  = The image location of the target MACHINE. Default to
#                       "./tmp/deploy/images/"
#
###############################################################################

set -uo pipefail

QEMU_RUN_TIMER=${QEMU_RUN_TIMER:-300}
QEMU_LOGIN_TIMER=${QEMU_LOGIN_TIMER:-180}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-openbmc/ubuntu-robot-qemu}
OBMC_BUILD_DIR=${OBMC_BUILD_DIR:-/tmp/openbmc/build}
UPSTREAM_WORKSPACE=${UPSTREAM_WORKSPACE:-${1}}
LAUNCH=${LAUNCH:-local}
DEFAULT_MACHINE=versatilepb
MACHINE=${MACHINE:-${DEFAULT_MACHINE}}
DEFAULT_IMAGE_LOC=${DEFAULT_IMAGE_LOC:-./tmp/deploy/images/}

# The automated test suite needs a real machine type so
# if we're using versatilepb for our qemu start parameter
# then we need to just let our run-robot use the default
if [[ "$MACHINE" == "$DEFAULT_MACHINE" ]]; then
    MACHINE_QEMU=
else
    MACHINE_QEMU=${MACHINE}
fi

# Determine the architecture
ARCH=$(uname -m)

# Determine the prefix of the Dockerfile's base image and the QEMU_ARCH variable
case ${ARCH} in
    "ppc64le")
        QEMU_ARCH="ppc64le-linux"
        ;;
    "x86_64")
        QEMU_ARCH="x86_64-linux"
        ;;
    "aarch64")
        QEMU_ARCH="arm64-linux"
        ;;
    *)
        echo "Unsupported system architecture(${ARCH}) found for docker image"
        exit 1
esac

# Set the location of the qemu binary relative to UPSTREAM_WORKSPACE
QEMU_BIN=${QEMU_BIN:-./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm}

# Get the base directory of the openbmc-build-scripts repo so we can return
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Create the base Docker image for QEMU and Robot
# shellcheck source=scripts/build-qemu-robot-docker.sh
. "$DIR/scripts/build-qemu-robot-docker.sh" "$DOCKER_IMG_NAME"

# Copy the scripts to start and verify QEMU in the workspace
cp "$DIR"/scripts/boot-qemu* "${UPSTREAM_WORKSPACE}"

################################################################################

if [[ ${LAUNCH} == "local" ]]; then

    # Start QEMU docker instance
    # root in docker required to open up the https/ssh ports
    obmc_qemu_docker=$(docker run --detach \
            --rm \
            --user root \
            --env HOME="${OBMC_BUILD_DIR}" \
            --env QEMU_RUN_TIMER="${QEMU_RUN_TIMER}" \
            --env QEMU_ARCH="${QEMU_ARCH}" \
            --env QEMU_BIN="${QEMU_BIN}" \
            --env MACHINE="${MACHINE}" \
            --env DEFAULT_IMAGE_LOC="${DEFAULT_IMAGE_LOC}" \
            --workdir "${OBMC_BUILD_DIR}"           \
            --volume "${UPSTREAM_WORKSPACE}:${OBMC_BUILD_DIR}:ro" \
            --tty \
        "${DOCKER_IMG_NAME}" "${OBMC_BUILD_DIR}"/boot-qemu-test.exp)

    # We can use default ports because we're going to have the 2
    # docker instances talk over their private network
    DOCKER_SSH_PORT=22
    DOCKER_HTTPS_PORT=443

    # This docker command intermittently asserts a SIGPIPE which
    # causes the whole script to fail. The IP address comes through
    # fine on these errors so just ignore the SIGPIPE
    trap '' PIPE

    DOCKER_QEMU_IP_ADDR="$(docker inspect "$obmc_qemu_docker" |  \
                       grep "IPAddress\":" | tail -n1 | cut -d '"' -f 4)"

    #Now wait for the OpenBMC QEMU Docker instance to get to standby
    delay=5
    attempt=$(( QEMU_LOGIN_TIMER / delay ))
    while [ $attempt -gt 0 ]; do
        attempt=$(( attempt - 1 ))
        echo "Waiting for qemu to get to standby (attempt: $attempt)..."
        result=$(docker logs "$obmc_qemu_docker")
        if grep -q 'OPENBMC-READY' <<< "$result" ; then
            echo "QEMU is ready!"
            # Give QEMU a few secs to stabilize
            sleep $delay
            break
        fi
        sleep $delay
    done

    if [ "$attempt" -eq 0 ]; then
        echo "Timed out waiting for QEMU, exiting"
        exit 1
    fi

    # Now run the Robot test (Tests commented out until they are working again)

    # Timestamp for job
    echo "Robot Test started, $(date)"

    mkdir -p "${WORKSPACE}"
    cd "${WORKSPACE}"

    # Copy in the script which will execute the Robot tests
    cp "$DIR"/scripts/run-robot.sh "${WORKSPACE}"

    # Run the Docker container to execute the Robot test cases
    # The test results will be put in ${WORKSPACE}
    docker run --rm \
        --env HOME="${HOME}" \
        --env IP_ADDR="${DOCKER_QEMU_IP_ADDR}" \
        --env SSH_PORT="${DOCKER_SSH_PORT}" \
        --env HTTPS_PORT="${DOCKER_HTTPS_PORT}" \
        --env MACHINE="${MACHINE_QEMU}" \
        --workdir "${HOME}" \
        --volume "${WORKSPACE}":"${HOME}" \
        --tty \
        "${DOCKER_IMG_NAME}" "${HOME}"/run-robot.sh

    # Now stop the QEMU Docker image
    docker stop "$obmc_qemu_docker"

else
    echo "LAUNCH variable invalid, Exiting"
    exit 1
fi
