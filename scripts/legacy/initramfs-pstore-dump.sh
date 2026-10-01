# Snippets inserted into the FriendlyWrt ramdisk's /init right after the
# `mount -t devtmpfs ... /dev` line.  They:
#
#   1) feed the RK3399 watchdog (/dev/watchdog or /dev/watchdog0) in a
#      background loop, bridging the gap until systemd takes over;
#   2) dump diagnostics (watchdog device state + dmesg) to /boot/boot-diag.txt
#      and the previous boot's pstore to /boot/pstore/, before switch_root.
#
# Rebuild the ramdisk with:
#   cd <extracted-ramdisk>
#   find . -print | cpio -o -H newc | gzip -9 > ref-fw/bsp-ramdisk-diag.gz
# then replace ::/bsp/ramdisk.gz in the FAT partition with the new file.

WDT=""
for d in /dev/watchdog /dev/watchdog0; do
	[ -c "$d" ] && WDT="$d" && break
done
if [ -n "$WDT" ]; then
	( while :; do printf '1' > "$WDT" 2>/dev/null; sleep 1; done ) &
fi

mkdir -p /tmp/diagmnt
MNT=0
for i in 1 2 3 4 5; do
	if mount -t vfat /dev/mmcblk1p1 /tmp/diagmnt 2>/dev/null; then
		MNT=1
		break
	fi
	sleep 1
done
if [ "$MNT" = "1" ]; then
	{
		echo "=== R4S initramfs diag ==="
		echo "--- watchdog dev ---"
		ls -la /dev/watchdog* 2>/dev/null
		if [ -n "$WDT" ]; then echo "feeding=$WDT"; else echo "no /dev/watchdog"; fi
		echo "--- watchdog sysfs ---"
		ls -la /sys/class/watchdog/ 2>/dev/null
		for f in /sys/class/watchdog/*/state /sys/class/watchdog/*/timeout; do
			[ -e "$f" ] && echo "$f: $(cat "$f" 2>/dev/null)"
		done
		echo "--- dmesg tail ---"
		dmesg 2>/dev/null | tail -100
		echo "--- dmesg watchdog/wdt lines ---"
		dmesg 2>/dev/null | grep -iE "watchdog|wdt|ramoops|pstore" | tail -60
	} > /tmp/diagmnt/boot-diag.txt 2>&1
	if [ -d /sys/fs/pstore ]; then
		mkdir -p /tmp/diagmnt/pstore
		cp -a /sys/fs/pstore/. /tmp/diagmnt/pstore/ 2>/dev/null
	fi
	sync
	umount /tmp/diagmnt
fi
