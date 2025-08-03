#!/bin/bash
set -ex

TMPDOWN=$1
INSTALL_MOD_PATH=$2
HERE=$(pwd)
source "${HERE}/deviceinfo"

KERNEL_DIR="${TMPDOWN}/$(basename "${deviceinfo_kernel_source}")"
KERNEL_DIR="${KERNEL_DIR%.git}"
OUT="${TMPDOWN}/KERNEL_OBJ"

mkdir -p "$OUT"

case "$deviceinfo_arch" in
    aarch64*) ARCH="arm64" ;;
    arm*) ARCH="arm" ;;
    x86_64) ARCH="x86_64" ;;
    x86) ARCH="x86" ;;
esac

export ARCH

# export CROSS_COMPILE="${deviceinfo_arch}-linux-android-"
# if [ "$ARCH" == "arm64" ]; then
#     export CROSS_COMPILE_ARM32=arm-linux-androideabi-
# fi
MAKEOPTS=""
if [ -n "$CC" ]; then
    MAKEOPTS="CC=$CC LD=$LD AR=$AR NM=$NM OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP STRIP=$STRIP READELF=$READELF"
fi

# 
HALIUM_CONFIG_PATH="arch/$ARCH/configs/halium.config"
# Create backup of original halium.config
if [ -f "$HALIUM_CONFIG_PATH" ]; then
    cp "$HALIUM_CONFIG_PATH" "$HALIUM_CONFIG_PATH.bak"
fi
touch "$HALIUM_CONFIG_PATH"
sed -i '/CONFIG_KSU=/d' "$HALIUM_CONFIG_PATH"
sed -i '/CONFIG_ALWAYS_PERMISSIVE=/d' "$HALIUM_CONFIG_PATH"

# SE Linux Config
if [[ "$SELINUX_MODE" == "permissive" ]]; then
    echo "Building SELinux Permissive Kernel"
    echo "CONFIG_ALWAYS_PERMISSIVE=y" >> "$HALIUM_CONFIG_PATH"
else
    echo "Building SELinux Enforced Kernel"
fi

# KSU Config
if [[ "$KERNELSU" =~ ^[yY]$ ]]; then
    echo "Building with KernelSU support"
    echo "CONFIG_KSU=y" >> "$HALIUM_CONFIG_PATH"
else
    echo "# CONFIG_KSU is not set" >> "$HALIUM_CONFIG_PATH"
fi

echo "Updated halium.config with SELinux and KernelSU settings"


cd "$KERNEL_DIR"

# Apply BPF kernel version spoof
if [[ "$BPF_SPOOF" == 1 ]]; then
    SPOOF_FILE=$(grep -Rsl '4\.9\.337' init kernel || true)
    [ -n "$SPOOF_FILE" ] && \
      sed -i 's/4\.9\.337/4.19.236/' "$SPOOF_FILE"
elif [[ "$BPF_SPOOF" == 2 ]]; then
    SPOOF_FILE=$(grep -Rsl '4\.19\.236' init kernel || true)
    [ -n "$SPOOF_FILE" ] && \
      sed -i 's/4\.19\.236/4.9.337/' "$SPOOF_FILE"
fi

make O="$OUT" $deviceinfo_kernel_defconfig
make O="$OUT" $MAKEOPTS -j$(nproc --all)
make O="$OUT" $MAKEOPTS INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$INSTALL_MOD_PATH" modules_install
ls "$OUT/arch/$ARCH/boot/"*Image*

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    ${TMPDOWN}/ufdt_apply_overlay "$OUT/arch/arm64/boot/dts/qcom/${deviceinfo_kernel_appended_dtb}.dtb" \
        "$OUT/arch/arm64/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}.dtbo" \
        "$OUT/arch/arm64/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}-merged.dtb"
    cat "$OUT/arch/$ARCH/boot/Image.gz" \
        "$OUT/arch/arm64/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}-merged.dtb" > "$OUT/arch/$ARCH/boot/Image.gz-dtb"
fi
