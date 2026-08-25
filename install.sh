#!/usr/bin/env bash
# systems-lab install script
set -euo pipefail

echo ""
echo "  [systems-lab] Installing — Linux Systems: boot, kernel, disks, recovery."
echo ""
echo "  This plugin boots ONE real virtual machine you will study, break and"
echo "  bring back to life. Unlike the browser labs, here the boot itself is"
echo "  real: firmware, bootloader, initramfs, /etc/fstab, a data disk."
echo ""
echo "  The idea that holds the lab together:"
echo "    A running SSH daemon is NOT proof that a machine boots. The proof is"
echo "    what the serial console says as PID 1 comes up from cold. So the"
echo "    exercises seed a real fault, power-cycle the machine, and read the"
echo "    verdict from the boot — not from a file on a disk that never rebooted."
echo ""

mkdir -p lab

echo "  Checking dependencies..."
ok=true
for cmd in qemu-system-x86_64 qemu-img genisoimage curl; do
    if command -v "$cmd" &>/dev/null; then echo "    [OK] $cmd"; else echo "    [!!] $cmd — not found"; ok=false; fi
done
if [[ "$ok" == true ]]; then
    echo ""; echo "  All dependencies available."
else
    echo ""; echo "  Install what is missing:  sudo apt install qemu-kvm qemu-utils genisoimage curl"
fi

echo ""
echo "  [systems-lab] Installation complete."
echo "  Run with:   qlab run systems-lab"
echo "  Then test:  qlab test systems-lab   (heavy: it power-cycles a real VM)"
