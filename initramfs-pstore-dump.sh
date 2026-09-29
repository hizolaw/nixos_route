# Snippets inserted into the FriendlyWrt ramdisk's /init (right after the
# `mount -t devtmpfs ... /dev` line).  Two things:
#
#   1) Feed the RK3399 watchdog.  The bootloader arms it with a short timeout
#      and systemd only starts feeding after switch_root, so this bridges the
#      gap and stops the reset loop.
#
#   2) Dump the *previous* boot's pstore/ramoops console+panic log onto the
#      FAT /boot partition before switch_root.
#
# Rebuild the ramdisk with:
#   cd <extracted-ramdisk>
#   find . -print | cpio -o -H newc | gzip -9 > ref-fw/bsp-ramdisk-diag.gz
# then replace ::/bsp/ramdisk.gz in the FAT partition with the new file.

if [ -c /dev/watchdog ]; then
	( while :; do printf '1' > /dev/watchdog 2>/dev/null; sleep 1; done ) &
fi

if [ -d /sys/fs/pstore ]; then
	mkdir -p /tmp/pstoremnt
	MNT=0
	for i in 1 2 3 4 5; do
		if mount -t vfat /dev/mmcblk1p1 /tmp/pstoremnt 2>/dev/null; then
			MNT=1
			break
		fi
		sleep 1
	done
	if [ "$MNT" = "1" ]; then
		mkdir -p /tmp/pstoremnt/pstore
		cp -a /sys/fs/pstore/. /tmp/pstoremnt/pstore/ 2>/dev/null
		sync
		umount /tmp/pstoremnt
	fi
fi
