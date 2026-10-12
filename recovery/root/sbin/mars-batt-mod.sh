#!/system/bin/sh
# v4.6 P3: load the battery charger module so the health HAL can expose
# /sys/class/power_supply/* and TWRP shows a real battery percentage.
LOG=/tmp/mars-batt-mod.log
MOD=/vendor/lib/modules/qti_battery_charger_main.ko
{
	echo "mars-batt-mod: waiting for $MOD"
	i=0
	while [ $i -lt 90 ]; do
		if [ -e "$MOD" ]; then
			echo "found after ${i}s, insmod:"
			insmod "$MOD" && echo "insmod ok" || echo "insmod failed ($?)"
			echo "power_supply now:"
			ls /sys/class/power_supply/ 2>&1
			[ -r /sys/class/power_supply/battery/capacity ] && cat /sys/class/power_supply/battery/capacity 2>&1
			exit 0
		fi
		i=$((i + 1))
		sleep 1
	done
	echo "module not found; /vendor/lib/modules:"
	ls -l /vendor/lib/modules 2>&1 | head -30
	exit 0
} >> "$LOG" 2>&1
