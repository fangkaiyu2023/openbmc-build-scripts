#!/bin/bash
###############################################################################
#
# 该脚本作用是在一个docker容器中自动构建qemu
# This build script is for running the QEMU build in a container
#
# 脚本运行的时候，必须有一个叫做$WORKSPACE/qemu的目录存放有qemu的源代码，其中这个WORKSPACE是一个环境变量
# It expects to be run in with the qemu source present in the directory called
# '$WORKSPACE/qemu', where WORKSPACE is an environment variable.
#
# 在 Jenkins中要按照如下配置，并且检出到一个叫做qemu的子目录
# In Jenkins configure the git SCM 'Additional Behaviours', 'check-out to a sub
# directory' called 'qemu'.
#
# 如果是在本地构建（本地是指主机，需要提前安装好docker），也需要把 WORKSPACE设置到qemu目录之上
# 具体：先cd ~，git再export WORKSPACE=$PWD(不要加qemu!),最后运行脚本： ~/openbmc-build-scripts/qemu-build.sh
# 手动构建qemu可以参考：https://zhuanlan.zhihu.com/p/622572068，但该构建只用于编译出qemu，并不会生成docker镜像
# When building locally set WORKSPACE to be the directory above the qemu
# checkout:
#   git clone https://github.com/qemu/qemu
#   WORKSPACE=$PWD/qemu ~/openbmc-build-scripts/qemu-build.sh
#
###############################################################################
#
# Script Variables:
#  http_proxy         The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set
#  WORKSPACE          Path of the workspace directory where the build will
#                     occur, and output artifacts will be produced.
#
###############################################################################
# Trace bash processing
#set -x

# Script Variables:
http_proxy=${http_proxy:-}

if [ -z ${WORKSPACE+x} ]; then
    echo "Please set WORKSPACE variable"
    exit 1
fi

# Determine the architecture
ARCH=$(uname -m)

# Docker Image Build Variables:
img_name=qemu-build

# Timestamp for job
echo "Build started, $(date)"

# Setup Proxy
if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
    "ppc64le")
        DOCKER_BASE="ppc64le/"
        ;;
    "x86_64")
        DOCKER_BASE=""
        ;;
    "aarch64")
        DOCKER_BASE="arm64v8/"
        ;;
    *)
        echo "Unsupported system architecture(${ARCH}) found for docker image"
        exit 1
esac

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# Go into the build directory
cd ${WORKSPACE}/qemu

gcc --version
git submodule update --init dtc
# disable anything that requires us to pull in X
./configure \
    --target-list=arm-softmmu \
    --disable-spice \
    --disable-docs \
    --disable-gtk \
    --disable-smartcard \
    --disable-usb-redir \
    --disable-libusb \
    --disable-sdl \
    --disable-gnutls \
    --disable-vte \
    --disable-vnc \
    --disable-werror
make clean
make -j4

EOF_SCRIPT

chmod a+x "${WORKSPACE}"/build.sh

# Configure docker build

#保持基础 docker 镜像与生成qemu二进制文件的那个镜像之间的同步？什么意思
# !!!
# Keep the base docker image in sync with the image under which we run the
# resulting qemu binary.
# !!!

Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:jammy

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy --no-install-recommends \
    bison \
    bzip2 \
    ca-certificates \
    flex \
    gcc \
    git \
    libc6-dev \
    libfdt-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    libslirp-dev \
    make \
    ninja-build \
    python3-yaml \
    iputils-ping

RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS[0]} ${USER}
USER ${USER}
ENV HOME ${HOME}
EOF
)

if ! docker build -t ${img_name} - <<< "${Dockerfile}" ; then
    echo "Failed to build docker container."
    exit 1
fi
# 下面的代码在ubuntu22 lts需要手动执行的，执行前需要导入环境变量。例如：
# export WORKSPACE=$PWD
# export img_name=qemu-build
docker run \
    --rm=true \
    -e WORKSPACE="${WORKSPACE}" \
    -w "${HOME}" \
    --user="${USER}" \
    -v "${HOME}":"${HOME}" \
    -t ${img_name} \
    "${WORKSPACE}"/build.sh
