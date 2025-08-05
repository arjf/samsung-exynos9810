#!/bin/bash
set -ex

TMPDOWN=$1
INSTALL_MOD_PATH=$2

[[ $# -lt 2 ]] && { echo "Usage: $0 <tmpdir> <install_mod_path>"; exit 1; }

HERE=$(pwd)
source "${HERE}/deviceinfo"
export ANDROID_MAJOR_VERSION=t
export PLATFORM_VERSION='13.0.0'
export CR_ARCH=arm64

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


# Fix for clang float-abi issue with ARM64
# Create a wrapper script to filter out problematic flags
CLANG_WRAPPER="$TMPDOWN/clang-wrapper.sh"
cat > "$CLANG_WRAPPER" << 'EOF'
#!/usr/bin/env bash
# Filter out -mfloat-abi= which is not supported for aarch64
ARGS=()
for arg in "$@"; do
    [[ $arg == --target=* ]] && continue
    if [[ "$arg" == -mfloat-abi=* || "$arg" == -mfpu=* ]]; then
        continue
    fi
    ARGS+=("$arg")
done
exec clang "${ARGS[@]}"
EOF
chmod +x "$CLANG_WRAPPER"

# Temporarily override CC to use our wrapper
ORIGINAL_CC="$CC"
export CC="$CLANG_WRAPPER"

MAKEOPTS=""
if [ -n "$CC" ]; then
    MAKEOPTS="LD=$LD AR=$AR NM=$NM OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP STRIP=$STRIP READELF=$READELF"
fi

cd "$KERNEL_DIR"

# 
# Generate combined defconfig similar to apollo.sh
BUILD_GENERATE_CONFIG() {
    echo "----------------------------------------------"
    echo " Generating combined defconfig for $deviceinfo_codename"
    echo " "
    
    DEFCONFIG_DIR="arch/$ARCH/configs"
    TMP_DEFCONFIG="$DEFCONFIG_DIR/tmp_defconfig"
    
    # Clean up
    [ -f "$TMP_DEFCONFIG" ] && rm -f "$TMP_DEFCONFIG"
    
    # Parse deviceinfo_kernel_defconfig
    read -ra configs <<< "$deviceinfo_kernel_defconfig"
    
    if [ -f "$DEFCONFIG_DIR/${configs[0]}" ]; then
        echo "Base config: ${configs[0]}"
        cp -f "$DEFCONFIG_DIR/${configs[0]}" "$TMP_DEFCONFIG"
    else
        echo "ERROR: Base config ${configs[0]} not found!"
        exit 1
    fi
    
    # Add remaining configs
    for ((i=1; i<${#configs[@]}; i++)); do
        if [ -f "$DEFCONFIG_DIR/${configs[$i]}" ]; then
            echo "Adding config: ${configs[$i]}"
            cat "$DEFCONFIG_DIR/${configs[$i]}" >> "$TMP_DEFCONFIG"
        else
            echo "WARNING: Config ${configs[$i]} not found, skipping..."
        fi
    done
    
    # SELinux Config
    if [[ "$SELINUX_MODE" == "permissive" ]]; then
        echo "Building SELinux Permissive Kernel"
        echo "CONFIG_ALWAYS_PERMISSIVE=y" >> "$TMP_DEFCONFIG"
    else
        echo "Building SELinux Enforced Kernel"
    fi
    
    # KSU Config
    if [[ "$KERNELSU" =~ ^[yY]$ ]]; then
        echo "Building with KernelSU support"
        echo "CONFIG_KSU=y" >> "$TMP_DEFCONFIG"
    else
        echo "# CONFIG_KSU is not set" >> "$TMP_DEFCONFIG"
    fi
    echo "CONFIG_MACH_EXYNOS9810_STAR2LTE_EUR_OPEN=y" >> "$TMP_DEFCONFIG"
    
    echo "Combined defconfig generated for $deviceinfo_codename"
    echo " "
}
 
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

BUILD_GENERATE_CONFIG
DEFCONFIG_DIR="arch/$ARCH/configs"


EGREP='grep -E' make O="$OUT" $MAKEOPTS tmp_defconfig
EGREP='grep -E' make O="$OUT" $MAKEOPTS olddefconfig 
EGREP='grep -E' make O="$OUT" $MAKEOPTS -j$(nproc --all)
EGREP='grep -E' make O="$OUT" $MAKEOPTS INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$INSTALL_MOD_PATH" modules_install
ls "$OUT/arch/$ARCH/boot/"*Image*

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    ${TMPDOWN}/ufdt_apply_overlay "$OUT/arch/arm64/boot/dts/exynos/${deviceinfo_kernel_appended_dtb}.dtb" \
        "$OUT/arch/arm64/boot/dts/exynos/${deviceinfo_kernel_dtb_overlay}.dtbo" \
        "$OUT/arch/arm64/boot/dts/exynos/${deviceinfo_kernel_dtb_overlay}-merged.dtb"
    cat "$OUT/arch/$ARCH/boot/Image.gz" \
        "$OUT/arch/arm64/boot/dts/exynos/${deviceinfo_kernel_dtb_overlay}-merged.dtb" > "$OUT/arch/$ARCH/boot/Image.gz-dtb"
fi

export CC="$ORIGINAL_CC"

if [ -f "$DEFCONFIG_DIR/tmp_defconfig" ]; then
    cp "$DEFCONFIG_DIR/tmp_defconfig" "$HERE/tmp_defconfig"
    rm -f "$DEFCONFIG_DIR/tmp_defconfig"
    echo "Saved combined defconfig to $HERE/tmp_defconfig"
fi