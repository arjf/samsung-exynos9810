#!/bin/bash
set -xe

BUILD_DIR=
OUT=
BPF_SPOOF=1       # 1=spoof 4.19.236, 2=revert
CLEAN_BUILD=n     # y=clean build directories
KERNELSU="y"
SELINUX_MODE="enforcing"

while [ $# -gt 0 ]
do
    case "$1" in
    (-b) BUILD_DIR="$(realpath "$2")"; shift;;
    (-o) OUT="$2"; shift;;
    (-s|--bpfspoof) BPF_SPOOF="$2"; shift;;
    (-C|--clean) CLEAN_BUILD=y;;
    (--enable-kernelsu|--ksu) KERNELSU="$2"; shift;;
    (--selinux-mode|--sel) SELINUX_MODE="$2"; shift;;
    (-*) echo "$0: Error: unknown option $1" 1>&2; exit 1;;
    (*) OUT="$2"; break;;
    esac
    shift
done

OUT="$(realpath "$OUT" 2>/dev/null || echo 'out')"
mkdir -p "$OUT"

if [ -z "$BUILD_DIR" ]; then
    TMP=$(mktemp -d)
    TMPDOWN=$(mktemp -d)
else
    TMP="$BUILD_DIR/tmp"
    mkdir -p "$TMP"
    TMPDOWN="$BUILD_DIR/downloads"
    mkdir -p "$TMPDOWN"
fi

HERE=$(pwd)
SCRIPT="$(dirname "$(realpath "$0")")"/build

mkdir -p "${TMP}/system"
mkdir -p "${TMP}/partitions"

source "${HERE}/deviceinfo"

deviceinfo_kernel_defconfig="${deviceinfo_kernel_defconfig:?deviceinfo_kernel_defconfig is unset}"
export BPF_SPOOF KERNELSU SELINUX_MODE

case $deviceinfo_arch in
    "armhf") RAMDISK_ARCH="armhf";;
    "aarch64") RAMDISK_ARCH="arm64";;
    "x86") RAMDISK_ARCH="i386";;
esac



cd "$TMPDOWN"
    # Get clang
    CLANG_DIR="$TMPDOWN/zyc-clang-22.0.0"
    CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/22.0.0git-20250803-release/Clang-22.0.0git-20250803.tar.gz"
    if [ ! -d "$CLANG_DIR/bin" ]; then
        echo "Fetching clang toolchain to $CLANG_DIR"
        mkdir -p "$CLANG_DIR"
        if [ -n "$CLANG_URL" ]; then
            curl -L "$CLANG_URL" | tar -xz -C "$CLANG_DIR"
        fi
    fi
    
    CLANG_PATH="$CLANG_DIR"
    KERNEL_DIR="$(basename "${deviceinfo_kernel_source}")"
    KERNEL_DIR="${KERNEL_DIR%.*}"
    [ -d "$KERNEL_DIR" ] || git clone --recurse-submodules "$deviceinfo_kernel_source" -b $deviceinfo_kernel_source_branch --depth 1
    
    # Clang optimizations
    if "$CLANG_PATH/bin/clang" --version | grep -qE ' 1[89]|2[0-9]'; then
        export CONFIG_THINLTO=y
        export CONFIG_UNIFIEDLTO=y
        export CONFIG_LLVM_MLGO_REGISTER=y
        export CONFIG_LLVM_POLLY=y
        export CONFIG_LLVM_DFA_JUMP_THREAD=y
    fi


    [ -f halium-boot-ramdisk.img ] || curl --location --output halium-boot-ramdisk.img \
        "https://github.com/halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-${RAMDISK_ARCH}"
    
    if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
        [ -d libufdt ] || git clone https://android.googlesource.com/platform/system/libufdt -b android12L-gsi --depth 1
        [ -d dtc ] || git clone https://android.googlesource.com/platform/external/dtc -b android12L-gsi --depth 1
    fi
    ls .
cd "$HERE"

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    "$SCRIPT/build-ufdt-apply-overlay.sh" "${TMPDOWN}"
fi

# Compat for gcc only trees
for prefix in arm-linux-androideabi; do
    for t in ar nm objcopy objdump ranlib strip; do
        ln -sf "$CLANG_PATH/bin/llvm-$t" "${CLANG_PATH}/bin/${prefix}-$t"
    done
done

# Set paths for llvm
export CC=$CLANG_PATH/bin/clang
export LD=$CLANG_PATH/bin/ld.lld
export AR=$CLANG_PATH/bin/llvm-ar
export NM=$CLANG_PATH/bin/llvm-nm
export OBJCOPY=$CLANG_PATH/bin/llvm-objcopy
export OBJDUMP=$CLANG_PATH/bin/llvm-objdump
export STRIP=$CLANG_PATH/bin/llvm-strip
export READELF=$CLANG_PATH/bin/llvm-readelf
export LLVM=1
export KALLSYMS_EXTRA_PASS=1

PATH="$CLANG_PATH/bin:${PATH}" \
"$SCRIPT/build-kernel.sh" "${TMPDOWN}" "${TMP}/system"


"$SCRIPT/make-bootimage.sh" "${TMPDOWN}/KERNEL_OBJ" "${TMPDOWN}/halium-boot-ramdisk.img" "${TMP}/partitions/boot.img"

cp -av overlay/* "${TMP}/"
[ -d "overlay-${deviceinfo_codename}" ] && cp -av "overlay-${deviceinfo_codename}"/* "${TMP}/"
"$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}"

if [ -z "$BUILD_DIR" ]; then
    rm -r "${TMP}"
    rm -r "${TMPDOWN}"
fi

echo "done"

