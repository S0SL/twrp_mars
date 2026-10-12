#!/usr/bin/env bash
# Lint every shell script this device tree ships (recovery/root/**/*.sh).
# Recovery runs Android mksh, which rejects bash-isms such as ${a.b} property
# expansions - the v4.7 firmware script died on exactly that ("bad substitution",
# /sbin/mars-fw-mount.sh[81]).
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
for f in $(find recovery/root -name '*.sh' -type f | sort); do
	if /bin/sh -n "$f" 2>/tmp/.shelllint.$$; then
		echo "  ok    $f"
	else
		echo "  FAIL  $f"; sed 's/^/        /' /tmp/.shelllint.$$
		rc=1
	fi
	rm -f /tmp/.shelllint.$$
	# property expansions like ${ro.boot.slot_suffix} are bash-only: mksh dies
	grep -nE '\$\{[A-Za-z_]+\.[A-Za-z_.]+\}' "$f" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' >/tmp/.shellprop.$$ || true
	if [ -s /tmp/.shellprop.$$ ]; then
		echo "  FAIL  $f uses a bash-style property expansion:"; sed 's/^/        /' /tmp/.shellprop.$$
		rc=1
	fi
	rm -f /tmp/.shellprop.$$
done
[ "$rc" = 0 ] && echo "check-shell: all scripts OK"
exit $rc
