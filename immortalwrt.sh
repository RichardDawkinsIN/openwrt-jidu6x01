#!/bin/bash
set -e

REPO_DIR=$(pwd)

sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
python3-setuptools rsync swig unzip zlib1g-dev file wget ccache tree

git clone https://github.com/immortalwrt/immortalwrt.git
cd immortalwrt

git checkout v25.12.0

git config --global user.email "ci@build.local"
git config --global user.name "CI Builder"

# Fetch the PR
git fetch https://github.com/openwrt/openwrt.git pull/23510/head:pr-23510

# Get only Jio-related commits and cherry-pick them dynamically
# (Some commits, e.g. JIDU6101 support, are already merged into mainline OpenWrt.
#  We try each commit individually and skip ones that are already applied or conflict,
#  instead of failing the whole build.)
JIO_COMMITS=$(git log pr-23510 --oneline --grep="jio\|jidu" --regexp-ignore-case --format="%H" | tac | \
  grep -v $(git log --format="%H" | head -100 | tr '\n' '\|' | sed 's/|$//'))

for commit in $JIO_COMMITS; do
  echo "Attempting to cherry-pick $commit"
  if git cherry-pick -X theirs "$commit"; then
    echo "  -> applied $commit"
  else
    echo "  -> skipping $commit (already applied or conflict)"
    git cherry-pick --abort 2>/dev/null || git cherry-pick --skip 2>/dev/null || true
  fi
done

echo "==============================adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="
# Add initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

for DEV in jiorouter_ax6000-jidu6101 jiorouter_ax6000-jidu6j01; do
  # Skip if this device already has the artifact (idempotent)
  if awk "/^define Device\/${DEV}\$/,/^endef/" "$FILOGIC_MK" | grep -q "initramfs-factory.ubi"; then
    echo "[$DEV] initramfs-factory.ubi already present, skipping"
    continue
  fi

  echo "[$DEV] adding initramfs-factory.ubi artifact"

  # Insert the artifact block before the sysupgrade line, but ONLY inside this device's block
  awk -v dev="$DEV" '
    $0 == "define Device/" dev { indev=1 }
    indev && /^  IMAGE\/sysupgrade\.bin := sysupgrade-tar \| append-metadata$/ {
      print "ifeq ($(IB),)"
      print "ifneq ($(CONFIG_TARGET_ROOTFS_INITRAMFS),)"
      print "  ARTIFACTS := initramfs-factory.ubi"
      print "  ARTIFACT/initramfs-factory.ubi := append-image-stage initramfs-kernel.bin | ubinize-kernel"
      print "endif"
      print "endif"
      indev=0
    }
    { print }
  ' "$FILOGIC_MK" > "${FILOGIC_MK}.tmp" && mv "${FILOGIC_MK}.tmp" "$FILOGIC_MK"
done
echo "==============================finished adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="

cat <<-EOF >> feeds.conf.default
src-git --root=feeds fantastic_packages https://github.com/fantastic-packages/packages.git;master
EOF

./scripts/feeds update -a
./scripts/feeds install -a

# Copy config and inject ccache dir dynamically
cp $REPO_DIR/${DEVICE_CONFIG} .config

make defconfig

echo "==============================adding fantastic package feeds=============================="
# --- Add fantastic-packages runtime feed (baked into firmware) ---
VER="25.12"
ARCH="aarch64_cortex-a53"
KEYID="20241123170031"   # from the grep above, WITHOUT the .pub extension

mkdir -p files/etc/apk/repositories.d
mkdir -p files/etc/apk/keys

# Correct feed URLs (github.io, not openwrt.org)
cat > files/etc/apk/repositories.d/customfeeds.list <<EOF
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/luci/packages.adb
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/packages/packages.adb
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/special/packages.adb
EOF

# Public key so apk trusts the feed (no --allow-untrusted needed)
curl -sSL -o "files/etc/apk/keys/${KEYID}.pem" \
  "https://fantastic-packages.github.io/releases/${VER}/${KEYID}.pub"

# Fail loudly if the key didn't download — don't ship a feed with no key
if [ ! -s "files/etc/apk/keys/${KEYID}.pem" ]; then
  echo "ERROR: fantastic-packages key download failed or empty"
  exit 1
fi
echo "Successfully added fantastic-packages feed with key ${KEYID}.pem"
echo "==============================finished adding fantastic package feeds=============================="

echo "==============================adding custom uci-defaults script=============================="
mkdir -p files/etc/uci-defaults

# Determine model name based on which device config is being built
case "$DEVICE_CONFIG" in
  *jidu6101*) MODEL_NAME="JioRouter AX6000 JIDU6101" ;;
  *jidu6j01*) MODEL_NAME="JioRouter AX6000 JIDU6J01" ;;
  *) MODEL_NAME="JioRouter AX6000" ;;
esac

cat > files/etc/uci-defaults/99-custom-config <<'EOF'

exec >/tmp/setup.log 2>&1

# 2.4GHz + 5GHz WiFi ON (no password, same SSID)
if [ -n "$wlan_name" ]; then
  uci set wireless.@wifi-device[0].disabled='0'
  uci set wireless.@wifi-iface[0].disabled='0'
  uci set wireless.@wifi-device[1].disabled='0'
  uci set wireless.@wifi-iface[1].disabled='0'
  uci commit wireless
  wifi reload
fi

# Custom LED script
cat > /usr/bin/led-wan << 'LEDEOF'
#!/bin/sh
trap 'exit 0' TERM INT

RED_LED="/sys/class/leds/red:status"
GREEN_LED="/sys/class/leds/green:status"
BLUE_LED="/sys/class/leds/blue:status"
PING_TARGETS="1.1.1.1 8.8.8.8"

set_led() {
    echo none > ${1}/trigger 2>/dev/null
    echo ${2} > ${1}/brightness 2>/dev/null
}

blink_led() {
    echo timer > ${1}/trigger 2>/dev/null
    echo ${2:-500} > ${1}/delay_on 2>/dev/null
    echo ${2:-500} > ${1}/delay_off 2>/dev/null
}

turn_off_all() {
    set_led "$RED_LED" 0
    set_led "$GREEN_LED" 0
    set_led "$BLUE_LED" 0
}

check_internet() {
    for target in $PING_TARGETS; do
        if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

is_upgrading() {
    pgrep -f "sysupgrade" >/dev/null 2>&1 && return 0
    [ -e /tmp/sysupgrade ] && return 0
    [ -e /overlay/.sysupgrade ] && return 0
    [ -e /tmp/.failsafe ] && return 0
    [ -f /tmp/sysupgrade.always_force_backup ] && return 0
    ls /tmp/sysupgrade-* >/dev/null 2>&1 && return 0
    return 1
}

while true; do
    if is_upgrading; then
        turn_off_all
        exit 0
    fi

    if check_internet; then
        turn_off_all
        set_led "$GREEN_LED" 1
    else
        turn_off_all
        blink_led "$RED_LED"
    fi

    sleep 5
done
LEDEOF
chmod +x /usr/bin/led-wan

# Init.d service with procd
cat > /etc/init.d/ledwan << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/led-wan
    procd_set_param respawn
    procd_close_instance
}
stop_service() {
    killall led-wan 2>/dev/null
}
restart() {
    stop
    start
}
INITEOF
chmod +x /etc/init.d/ledwan
/etc/init.d/ledwan enable
/etc/init.d/ledwan start

# =========================================================
# CUSTOM MODEL NAME
# =========================================================

cat >/etc/init.d/custom-model << 'MODELEOF'
#!/bin/sh /etc/rc.common

START=99

start() {
    mkdir -p /tmp/sysinfo
    echo "__MODEL_NAME__" >/tmp/sysinfo/model
}
MODELEOF
chmod +x /etc/init.d/custom-model
/etc/init.d/custom-model enable
/etc/init.d/custom-model start

echo "All done!"
EOF

# Inject the correct model name for this specific device build
sed -i "s|__MODEL_NAME__|${MODEL_NAME}|" files/etc/uci-defaults/99-custom-config
chmod +x files/etc/uci-defaults/99-custom-config
echo "==============================finished adding custom uci-defaults script=============================="

make -j$(nproc)

echo "Build completed successfully! Artifacts are located in bin/targets/mediatek/filogic/"
