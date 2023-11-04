#!/bin/sh

set -e

if [ "$(id -u)" != "0" ]; then
    echo "[!] Run as root"
    exit 1
fi

ROOTDIR="$(pwd)"
CACHEDIR="$ROOTDIR/cache"
ROOTFS_DIR="$CACHEDIR/rootfs"
INITRD_DIR="$CACHEDIR/initrd"
OUT_DIR="$CACHEDIR/out"
ISO_DIR="$CACHEDIR/iso"
REPO="edge"
REPO_FILE="$(mktemp)"
ROOTFS_PACKAGES="alpine-base alpine-baselayout alpine-conf apk-tools gcc busybox openrc busybox-openrc"

echo "[*] Cleaning up before build..."
rm -rf "$CACHEDIR"

echo "[*] Alpine Base Repository: $REPO"

cat << EOF > "$REPO_FILE"
http://dl-cdn.alpinelinux.org/alpine/${REPO}/main
http://dl-cdn.alpinelinux.org/alpine/${REPO}/community
http://dl-cdn.alpinelinux.org/alpine/${REPO}/testing
EOF

echo "[*] Repositories:"
cat "$REPO_FILE"

echo "[*] Setting up APK in initrd..."
mkdir -p "$INITRD_DIR"

echo "[*] Downloading initrd packages..."
echo " - Current: Linux Kernel"
cd "$INITRD_DIR"
apk fetch --repositories-file "$REPO_FILE" -s linux-lts > linux-lts.apk
tar -xzvf linux-lts.apk
rm linux-lts.apk

echo " - Current: Busybox"
apk fetch --repositories-file "$REPO_FILE" -s busybox > busybox.apk
tar -xzvf busybox.apk
rm busybox.apk

echo " - Current: Musl Libc"
apk fetch --repositories-file "$REPO_FILE" -s musl > musl.apk
tar -xzvf musl.apk
rm musl.apk

cd "$ROOTDIR"

echo "[*] Installing busybox on initrd..."
mkdir -p "$INITRD_DIR/usr/bin" # busybox install fails without this
chroot "$INITRD_DIR" /bin/busybox --install

echo "[*] Setting up APK in rootfs..."
mkdir -p "$ROOTFS_DIR"
apk add --initdb --root "$ROOTFS_DIR"
cp "$REPO_FILE" "$ROOTFS_DIR/etc/apk/repositories"

echo "[*] Downloading/Installing rootfs packages..."
apk update --root "$ROOTFS_DIR" --allow-untrusted
apk add --root "$ROOTFS_DIR" --allow-untrusted $ROOTFS_PACKAGES

echo "[*] Making ISO..."
mkdir -p "$ISO_DIR"

echo " - Relocating kernel..."
cd "$ISO_DIR"
mv "$INITRD_DIR/boot" ./

# TOFIX: Not working with stock alpine linux-lts kernel due to some issue with kernel modules.
# A Linux compiled with generic config + squashfs + overlayfs works fine.

echo " - Creating GRUB configuration file..."
mkdir -p "boot/grub"
cat << EOF > boot/grub/grub.cfg
insmod all_video
insmod gfxterm

loadfont /boot/grub/fonts/unicode.pf2

set timeout=5
set gfxmode=640x480
terminal_output gfxterm

menuentry "Alpine Linux (squash rootfs)" {
    echo "Loading vmlinuz..."
    linux /boot/vmlinuz-lts modules=squash,overlay
    echo "Loading initrd..."
    initrd /boot/initrd
}
EOF

echo " - Creating init script..."
cd "$INITRD_DIR"
cat << EOF > init
#!/bin/sh

echo "Starting Alpine Linux (squash rootfs)..."
dmesg -n 1

echo "Mounting Linux filesystems..."
mkdir -p /dev /proc /sys /tmp
mount -t devtmpfs none /dev
mount -t proc none /proc
mount -t sysfs none /sys
mount -t tmpfs none /tmp
mkdir -p /dev/pts
mount -t devpts none /dev/pts
mdev -s

echo "Mounting cdrom..."
mkdir -p /cdrom
mount /dev/sr0 /cdrom

echo "Mounting overlay..."
mkdir -p /squash /upper /work /newroot
mount -t squashfs /cdrom/squash.rootfs /squash
mount -t overlay -o lowerdir=/squash,upperdir=/upper,workdir=/work overlayfs /newroot

echo "Run 'exit' to enter overlayfs chroot..."
setsid cttyhack /bin/sh

chroot /newroot
EOF
chmod +x init

echo " - Creating initrd archive..."
find . | cpio -R root:root -H newc -o | gzip > "$ISO_DIR/boot/initrd"
cd "$ISO_DIR"

echo " - Creating squash rootfs..."
mksquashfs "$ROOTFS_DIR" "$ISO_DIR/squash.rootfs"

echo " - Running grub-mkrescue..." # NOTE: Make sure to have grub-bios and grub-efi installed
mkdir -p "$OUT_DIR"
grub-mkrescue "$ISO_DIR" -o "$OUT_DIR/alpine-squash-rootfs.iso"

rm "$REPO_FILE"