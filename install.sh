#!/bin/bash

trap onexit 1 2 3 15 ERR EXIT
#--- onexit() -----------------------------------------------------
#  @param $1 integer  (optional) Exit status.  If not set, use `$?'

onexit() {
    # any items needed for cleanup here.
    local exit_status=${1:-$?}
    if [ ${exit_status} == 0 ]
    then
        exit
    fi
    exit $exit_status
}

log() {
    printf "\n\033[32m$*\033[00m\n"
    read -p "Press [enter] to continue." KEY
}

EMMC="/dev/mmcblk0"
DEFAULT_USB="/dev/sda"
DEVICE=${1:-$DEFAULT_USB}

if [ "$DEVICE" = "$EMMC" ]; then
    P1="${DEVICE}p1"
    P2="${DEVICE}p2"
    P3="${DEVICE}p3"
    P12="${DEVICE}p12"
else
    P1="${DEVICE}1"
    P2="${DEVICE}2"
    P3="${DEVICE}3"
    P12="${DEVICE}12"
fi

OSHOST="http://archlinuxarm.org/os/"
#OSFILE="ArchLinuxARM-peach-latest.tar.gz"
OSFILE="ArchLinuxARM-armv7-chromebook-latest.tar.gz"
BOOTFILE="boot.scr.uimg"
UBOOTHOST="https://github.com/omgmog/nv_uboot-spring/raw/master/"
UBOOTFILE="nv_uboot-spring.kpart.gz"
GITHUBUSER="Stuw"
REPOFILES="https://raw.githubusercontent.com/${GITHUBUSER}/archarm-usb-hp-chromebook-11"
ARCH="$(uname -m)"

log "Ensure cgpt is available"
if (which cgpt >/dev/null 2>&1 ); then
	echo "cgpt is installed"
	cgpt="cgpt"
else
	echo "Getting working cgpt binary"
	mkdir -p /usr/local/bin
	curl -L ${REPOFILES}/master/deps/cgpt -o /usr/local/bin/cgpt
	chmod +x /usr/local/bin/cgpt
	cgpt="/usr/local/bin/cgpt"
fi

if [ $DEVICE = $EMMC ]; then
    if [ -L /usr/sbin ]; then
	rm -f /usr/sbin
    fi
    # for eMMC we need to get some things before we can partition
    pacman -Syu --needed packer devtools-alarm base-devel git libyaml parted dosfstools parted
    pacman -S --needed --noconfirm vboot-utils
    log "When prompted to modify PKGBUILD for trousers, set arch to armv7h"
    useradd -c 'Build user' -m build
    su -c "packer -S trousers" build
    userdel -r build > /dev/null 2>&1
    if [ ! -L /usr/sbin ] && [ ! -d /usr/sbin ]; then
	ln -s /usr/bin /usr/sbin
    fi
else
	if [ "x$ARCH" != "xarmv7l" ]; then
	    log "Ensuring the proper paritioning tools are availible"
	    if (which parted > /dev/null 2>&1 ); then
			echo "parted is installed. Installation can proceed"
	    else
			echo "parted must be downloaded !"
			log "When prompted to install virtual/target-os-dev press N"
			dev_install
			emerge parted
	    fi
	fi
fi


if [ "x$ARCH" != "xarmv7l" ]; then
	log "Creating volumes on ${DEVICE}"
	for mnt in `mount | grep ${DEVICE} | awk '{print $1}'`;do
	    umount ${mnt}
	done
	parted ${DEVICE} mklabel gpt
	"$cgpt" create -z ${DEVICE}
	"$cgpt" create ${DEVICE}
	"$cgpt" add -i 1 -t kernel -b 8192 -s 32768 -l U-Boot -S 1 -T 5 -P 10 ${DEVICE}
	"$cgpt" add -i 2 -t data -b 40960 -s 32768 -l Kernel ${DEVICE}
	"$cgpt" add -i 12 -t data -b 73728 -s 32768 -l Script ${DEVICE}
	PARTSIZE=`"$cgpt" show ${DEVICE} | grep 'Sec GPT table' | egrep -o '[0-9]+' | head -n 1`
	"$cgpt" add -i 3 -t data -b 106496 -s `expr ${PARTSIZE} - 106496` -l Root ${DEVICE}
	partprobe ${DEVICE}
	mkfs.ext2 $P2
	mkfs.ext4 $P3
	mkfs.vfat -F 16 $P12
else
	log "Formatting volumes on ${DEVICE}"
	for mnt in `mount | grep ${DEVICE} | awk '{print $1}'`;do
	    umount ${mnt}
	done
	mkfs.ext2 $P2
	mkfs.ext4 $P3
	mkfs.vfat -F 16 $P12
fi

# We will need it later
cp install.sh /tmp

cd /tmp

if [ ! -f "${OSFILE}" ]; then
    log "Downloading ${OSFILE}"
    curl -L ${OSHOST}${OSFILE} -o ${OSFILE}
else
    log "Looks like you already have ${OSFILE}"
fi
log "Installing Arch to ${P3} (this will take a moment...)"
for mnt in `mount | grep ${DEVICE} | awk '{print $1}'`;do
    umount ${mnt}
done
mkdir -p root
mount -o exec $P3 root
tar -xf ${OSFILE} -C root > /dev/null 2>&1

log "Preparing system for chroot"
if [ $DEVICE != $EMMC ]; then
    cp install.sh root/install.sh
fi
rm root/etc/resolv.conf
cp /etc/resolv.conf root/etc/resolv.conf
mount -t proc proc root/proc/
mount --rbind /sys root/sys/
mount --rbind /dev root/dev/
log "downloading old version of systemd and pacman.conf"
rm root/etc/pacman.conf
curl -L ${REPOFILES}/master/deps/systemd-212-3-armv7h.pkg.tar.xz -o root/systemd-212-3-armv7h.pkg.tar.xz
curl -L ${REPOFILES}/master/deps/pacman.conf -o root/etc/pacman.conf
curl -L ${REPOFILES}/master/post-install.sh -o root/post-install.sh
log "downloading systemd fix script"
curl -L ${REPOFILES}/master/fix-systemd.sh -o root/fix-systemd.sh
chmod +x root/fix-systemd.sh
chroot root/ /bin/bash -c "/fix-systemd.sh"

if [ ! -f "root/boot/${BOOTFILE}" ]; then
    log "Downloading ${BOOTFILE}"
    curl -L -o "root/boot/${BOOTFILE}" "${OSHOST}exynos/${BOOTFILE}"
else
    log "Looks like we already have boot.scr.uimg"
fi

mkdir -p mnt

if [ ! -f root/boot/vmlinux.uimg ]; then
	echo "Create vmlinux.uimg from zImage"
	mkimage -A arm -O linux -T kernel -C none -a 0x40009000 -e 0x40009000 -n Linux -d root/boot/zImage root/boot/vmlinux.uimg
fi

mount $P2 mnt
cp root/boot/vmlinux.uimg mnt
umount mnt

mount $P12 mnt
mkdir -p mnt/u-boot
cp root/boot/boot.scr.uimg mnt/u-boot
umount mnt

if [ $DEVICE != $EMMC ]; then
    log "Copying over devkeys (to generate kernel later)"
    mkdir -p /tmp/root/usr/share/vboot/devkeys
    cp -r /usr/share/vboot/devkeys/ /tmp/root/usr/share/vboot/
fi

if [ $DEVICE = $EMMC ]; then
    echo "root=${P3} rootwait rw quiet lsm.module_locking=0" >config.txt

    /usr/sbin/vbutil_kernel \
    --pack arch-eMMC.kpart \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --config config.txt \
    --vmlinuz /boot/vmlinux.uimg \
    --arch arm \
    --version 1

    dd if=arch-eMMC.kpart of=$P1

    sync

    log "All done! Reboot and press ctrl + D to boot Arch"
else
    if [ ! -f "${UBOOTFILE}" ]; then
        log "Downloading ${UBOOTFILE}"
        curl -L ${UBOOTHOST}${UBOOTFILE} -o ${UBOOTFILE}
    else
        log "Looks like you already have ${UBOOTFILE}"
    fi
    gunzip -f ${UBOOTFILE}
    dd if=nv_uboot-spring.kpart of=$P1

    sync

    log "All done! Reboot and press ctrl + U to boot Arch from ${DEVICE}"
fi
