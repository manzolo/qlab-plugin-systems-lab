#!/usr/bin/env bash
# systems-lab run script — boots the TARGET VM: the machine you study, break and
# recover. One extra virtual data disk (/dev/vdb) for the storage chapters. The
# rescue machine is not booted here — it is spun up on demand (by the tests, or
# by lab/rescue.sh) with this target's disk attached, because two live writers on
# one qcow2 corrupt it.
#
# Skeleton and cloud-init borrowed from lvm-lab and cyber-lab; the serial log is
# the standard qlab -serial file:, which the bench (lib/banco.sh) reads as the
# boot oracle.

set -euo pipefail

PLUGIN_NAME="systems-lab"
TARGET_VM="systems-lab-target"

echo "============================================="
echo "  systems-lab: Linux Systems (the boot IS the test)"
echo "============================================="
echo ""
echo "  One VM you will study, break and bring back:"
echo ""
echo "    $TARGET_VM"
echo "      Ubuntu on a real virtual machine — real firmware, real bootloader,"
echo "      real initramfs, an extra data disk on /dev/vdb. When an exercise"
echo "      breaks the boot, you recover it from a rescue system (sys-02),"
echo "      not by editing a file the machine never re-read."
echo ""

# Source QLab core libraries
if [[ -z "${QLAB_ROOT:-}" ]]; then
    echo "ERROR: QLAB_ROOT not set. Run this plugin via 'qlab run ${PLUGIN_NAME}'."
    exit 1
fi
for lib_file in "$QLAB_ROOT"/lib/*.bash; do
    # shellcheck source=/dev/null
    [[ -f "$lib_file" ]] && source "$lib_file"
done

WORKSPACE_DIR="${WORKSPACE_DIR:-.qlab}"
LAB_DIR="lab"
IMAGE_DIR="$WORKSPACE_DIR/images"
CLOUD_IMAGE_URL=$(get_config CLOUD_IMAGE_URL "https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img")
CLOUD_IMAGE_FILE="$IMAGE_DIR/ubuntu-22.04-minimal-cloudimg-amd64.img"
MEMORY="${QLAB_MEMORY:-$(get_config DEFAULT_MEMORY 1024)}"
DATA_DISK="$LAB_DIR/systems-lab-data.qcow2"

mkdir -p "$LAB_DIR" "$IMAGE_DIR"

# =============================================
# Step 1: Cloud image
# =============================================
info "Step 1: Cloud image"
if [[ -f "$CLOUD_IMAGE_FILE" ]]; then
    success "Cloud image already downloaded: $CLOUD_IMAGE_FILE"
else
    info "Downloading Ubuntu cloud image..."
    check_dependency curl || exit 1
    curl -L -o "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL" || { error "Download failed."; exit 1; }
    success "Cloud image downloaded."
fi
echo ""

# =============================================
# Step 2: Cloud-init for the target
# =============================================
info "Step 2: Cloud-init configuration"

cat > "$LAB_DIR/user-data-target" <<'USERDATA'
#cloud-config
hostname: systems-lab-target
users:
  - name: labuser
    plain_text_passwd: labpass
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - "__QLAB_SSH_PUB_KEY__"
ssh_pwauth: true
package_update: false
packages:
  - vim
  - nano
  - gdisk
  - cryptsetup
USERDATA

cat > "$LAB_DIR/meta-data-target" <<META
instance-id: systems-lab-target
local-hostname: systems-lab-target
META

# Inject the workspace SSH public key (qlab core exports QLAB_SSH_PUB_KEY).
sed -i "s|__QLAB_SSH_PUB_KEY__|${QLAB_SSH_PUB_KEY:-}|g" "$LAB_DIR/user-data-target"

check_dependency genisoimage || { error "genisoimage not found: sudo apt install genisoimage"; exit 1; }
CIDATA_TARGET="$LAB_DIR/cidata-target.iso"
genisoimage -output "$CIDATA_TARGET" -volid cidata -joliet -rock \
    -graft-points "user-data=$LAB_DIR/user-data-target" "meta-data=$LAB_DIR/meta-data-target" 2>/dev/null
success "Cloud-init ISO ready."
echo ""

# =============================================
# Step 3: Overlay + data disk
# =============================================
info "Step 3: Disks"
OVERLAY_TARGET="$LAB_DIR/systems-lab-target-disk.qcow2"
[[ -f "$OVERLAY_TARGET" ]] && rm -f "$OVERLAY_TARGET"
create_overlay "$CLOUD_IMAGE_FILE" "$OVERLAY_TARGET" "${QLAB_DISK_SIZE:-6G}" || { error "overlay failed"; exit 1; }
# The extra data disk: empty, for the storage chapters (sys-04/05). 1G is plenty.
[[ -f "$DATA_DISK" ]] && rm -f "$DATA_DISK"
create_disk "$DATA_DISK" "${QLAB_DATA_SIZE:-1G}"
success "Boot overlay + 1 data disk (/dev/vdb) ready."
echo ""

# =============================================
# Step 4: Boot the target
# =============================================
info "Step 4: Starting $TARGET_VM"
start_vm "$OVERLAY_TARGET" "$CIDATA_TARGET" "$MEMORY" "$TARGET_VM" auto \
    "-drive" "file=$DATA_DISK,format=qcow2,if=virtio"

echo ""
echo "============================================="
echo "  systems-lab: target is booting"
echo "============================================="
echo ""
echo "  Credentials:  labuser / labpass"
echo ""
echo "  Connect (wait ~60s for first boot + packages):"
echo "    qlab shell $TARGET_VM"
echo ""
echo "  The exercises and the boot oracle live in the test suite and guide.md."
echo "  When a chapter breaks the boot, recover from a rescue system:"
echo "    bash lab/rescue.sh          # boots a rescue VM with the target disk"
echo ""
