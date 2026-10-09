#!/usr/bin/env bash
#
# mars (Xiaomi Mi 11 Pro) OrangeFox recovery -- self-healing build entrypoint.
#
# Run by systemd (see scripts/mars-build.service).  Designed so the build
# survives an SSH outage, a reboot, and a flaky network **without anyone
# logging in**:
#
#   * idempotent  -- flock'd (one writer at a time), exits immediately once
#                    dist/boot.img exists, and records a stamp after a
#                    successful sync so later starts skip straight to the build;
#   * self-healing-- retries the flaky parts, and systemd restarts it on failure;
#   * memory-guard-- pauses the heavy network fetches when MemAvailable drops,
#                    so a full-history fetch can never take sshd or the tunnel
#                    client down with it.
#
# It never flashes a device, never touches the kernel repository and never
# triggers a CI run.
#
# Environment knobs (all optional):
#   MARS_HOME        default /home/shen
#   MARS_JOBS        build parallelism, default 4 (this box has 4 cores / 15 GB)
#   MARS_MEM_LOW_MB  pause fetches below this MemAvailable, default 1200
#   MARS_MEM_HIGH_MB resume fetches above this, default 2800
#   FOX_BUILD_TYPE   default Unofficial
#   MARS_FORCE=1     rebuild even if dist/boot.img already exists

set -uo pipefail

HOME_DIR="${MARS_HOME:-/home/shen}"
FOX_DIR="$HOME_DIR/fox_14.1"
TREE="$HOME_DIR/twrp-mars"
LOG_DIR="$HOME_DIR/logs"
DIST="$TREE/dist"
STAMP="$HOME_DIR/.mars-sync-complete"
JOBS="${MARS_JOBS:-4}"
MEM_LOW="${MARS_MEM_LOW_MB:-1200}"
MEM_HIGH="${MARS_MEM_HIGH_MB:-2800}"

# the two projects that repeatedly died: repo drops --depth=1 for any project
# whose directory already exists, turning a ~1 GB fetch into 10-20 GB of history
GIANTS="platform/prebuilts/rust platform/prebuilts/clang/host/linux-x86"

# a pgrep/pkill pattern that cannot match this script's own command line
HEAVY='git-remote-https|index-pack|git fetch|main.py.*sync'

mkdir -p "$LOG_DIR"
say() { echo "[$(date -u +%FT%TZ)] $*"; }

# ---------------------------------------------------------------- one writer
exec 9>"$HOME_DIR/.mars-build.lock"
if ! flock -n 9; then
	say "another mars-build instance holds the lock -- nothing to do"
	exit 0
fi

export PATH="$HOME_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C
export FOX_BUILD_DEVICE=mars
export FOX_BUILD_TYPE="${FOX_BUILD_TYPE:-Unofficial}"
export ALLOW_MISSING_DEPENDENCIES=true
export USE_CCACHE=1
export CCACHE_DIR="$FOX_DIR/.ccache"
CCACHE_EXEC="$(command -v ccache || true)"
[ -n "$CCACHE_EXEC" ] && export CCACHE_EXEC

say "===== mars-build start (host $(hostname), jobs $JOBS) ====="
df -h "$HOME_DIR" | tail -1
awk '/MemTotal|MemAvailable/{printf "  %s %.1f GB\n", $1, $2/1048576}' /proc/meminfo

# ---------------------------------------------------------------- dry run
if [ "${MARS_DRY_RUN:-0}" = 1 ]; then
	say "MARS_DRY_RUN=1 -- checks only, no build"
	command -v repo >/dev/null && say "ok repo $(repo --version 2>/dev/null | head -1)" || say "MISSING repo"
	[ -d "$FOX_DIR/.repo" ] && say "ok tree $FOX_DIR" || say "MISSING tree $FOX_DIR"
	[ -f "$TREE/scripts/build-local.sh" ] && say "ok device tree $TREE" || say "MISSING device tree $TREE"
	[ -f "$STAMP" ] && say "sync stamp present" || say "no sync stamp yet"
	[ -f "$DIST/boot.img" ] && say "artifact already present: $DIST/boot.img" || say "no artifact yet"
	exit 0
fi

# ---------------------------------------------------------------- memory guard
#
# IMPORTANT DESIGN CONSTRAINTS (a first version of this got them wrong):
#
#  * SIGSTOP does NOT release memory.  So a guard that resumes only when
#    MemAvailable climbs back above a high watermark can deadlock forever: the
#    stopped process keeps holding its pages, the watermark is never reached and
#    nobody ever sends SIGCONT.  Resume therefore happens on **whichever comes
#    first**: memory recovering *or* a hard timeout.
#  * Only network/fetch processes are ever stopped.  Never soong_build, ninja,
#    mka, make, cc1plus or any shell in the build chain -- the pattern below
#    matches git/repo networking only, and the guard additionally refuses to
#    touch anything whose executable is a compiler or a build tool.
#  * It logs a heartbeat, so the log can never look hung just because Soong's
#    analysis phase prints nothing for an hour.
#
# MARS_MEM_GUARD=0 disables the whole thing (swap is the safer fallback).
PAUSED=0
PAUSED_SINCE=0
GUARD_TICKS=0
MEM_STOP_MAX="${MARS_MEM_STOP_MAX:-90}"
HEARTBEAT_TICKS="${MARS_MEM_HEARTBEAT_S:-300}"

guard_safe_to_stop() {
	# never stop a build/compile process, whatever the pattern matched
	case "$(cat "/proc/$1/comm" 2>/dev/null)" in
	soong_build|soong_ui|ninja|nsjail|mka|make|cc1plus|cc1|gcc|g++|ld|clang*|javac|d8|r8|kotlinc*|bash|dash|sh|systemd|sshd)
		return 1 ;;
	esac
	return 0
}

guard_stop() {
	local p n=0
	for p in $(pgrep -f "$HEAVY" 2>/dev/null); do
		[ "$p" = "$$" ] && continue
		if guard_safe_to_stop "$p"; then kill -STOP "$p" 2>/dev/null && n=$((n + 1)); fi
	done
	echo "$n"
}

guard_cont() {
	local p
	for p in $(pgrep -f "$HEAVY" 2>/dev/null); do
		kill -CONT "$p" 2>/dev/null
	done
}

mem_guard() {
	[ "${MARS_MEM_GUARD:-1}" = 1 ] || { say "MEM GUARD disabled (MARS_MEM_GUARD=0)"; return 0; }
	while :; do
		local avail now
		avail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
		now=$(date +%s)
		if [ "$PAUSED" = 0 ] && [ "${avail:-0}" -lt "$MEM_LOW" ]; then
			local stopped
			stopped=$(guard_stop)
			if [ "${stopped:-0}" -gt 0 ]; then
				say "MEM GUARD: MemAvailable ${avail}MB < ${MEM_LOW}MB -- paused $stopped fetch/network process(es) (max ${MEM_STOP_MAX}s)"
				PAUSED=1
				PAUSED_SINCE=$now
			else
				# nothing to pause (no fetch running): warn once in a while but do
				# NOT enter the paused state, otherwise the guard would cycle
				# pause/resume every 90 s and spam the log for no reason
				[ $((GUARD_TICKS % 180)) -lt 10 ] && \
					say "MEM GUARD: MemAvailable ${avail}MB is low but no fetch/network process is running -- nothing to pause (build unaffected)"
			fi
		elif [ "$PAUSED" = 1 ]; then
			if [ "${avail:-0}" -gt "$MEM_HIGH" ] || [ $((now - PAUSED_SINCE)) -ge "$MEM_STOP_MAX" ]; then
				say "MEM GUARD: resuming after $((now - PAUSED_SINCE))s (MemAvailable ${avail}MB) -- SIGCONT"
				guard_cont
				PAUSED=0
			fi
		fi
		GUARD_TICKS=$((GUARD_TICKS + 10))
		if [ "$GUARD_TICKS" -ge "$HEARTBEAT_TICKS" ]; then
			GUARD_TICKS=0
			say "MEM GUARD alive: MemAvailable ${avail}MB, swap_free $(free -m | awk '/[Ss]wap|交换/{print $4}')MB, paused=$PAUSED, soong=$(pgrep -c -f 'soong_build' 2>/dev/null || echo 0) ninja=$(pgrep -c -f 'bin/ninja' 2>/dev/null || echo 0) cc1plus=$(pgrep -c cc1plus 2>/dev/null || echo 0) out=$(du -sh "$FOX_DIR/out" 2>/dev/null | cut -f1)"
		fi
		sleep 10
	done
}
mem_guard &
GUARD_PID=$!
cleanup() {
	kill "$GUARD_PID" 2>/dev/null
	# never leave a stopped process behind
	guard_cont
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- preflight
[ -d "$TREE" ] || { say "FATAL: device tree $TREE is missing"; exit 1; }
[ -d "$FOX_DIR/.repo" ] || say "note: $FOX_DIR has no .repo yet -- the sync phase will create it"
if ! command -v repo >/dev/null 2>&1; then
	say "FATAL: repo is not on PATH ($HOME_DIR/bin/repo)"
	exit 1
fi

# ---------------------------------------------------------------- already built?
if [ -f "$DIST/boot.img" ] && [ "${MARS_FORCE:-0}" != 1 ]; then
	say "dist/boot.img already exists -- nothing to do (MARS_FORCE=1 to rebuild)"
	ls -l "$DIST"
	sha256sum "$DIST"/* 2>/dev/null
	exit 0
fi
mkdir -p "$HOME_DIR/bin"

# ---------------------------------------------------------------- sync phase
# Clear a project directory that holds only failed tmp packs.  repo only passes
# --depth=1 to projects it considers NEW, so a leftover directory silently turns
# every retry into a full-history transfer (see docs/BUILD-STATUS.md, S2).
repair_giants() {
	local proj d wt g attempt

	# Note the two different paths: the object dir is keyed by the project
	# *name* (platform/prebuilts/rust), the work git-dir by its *path*
	# (prebuilts/rust).
	clear_locks() {
		find "$FOX_DIR/.repo/projects" -maxdepth 7 -name 'index.lock' -mmin +2 -delete 2>/dev/null
		find "$FOX_DIR/.repo/projects" -maxdepth 7 -name 'shallow.lock' -mmin +2 -delete 2>/dev/null
		find "$FOX_DIR/.repo/project-objects" -maxdepth 7 -name 'index.lock' -mmin +2 -delete 2>/dev/null
	}

	clear_locks
	for proj in $GIANTS; do
		d="$FOX_DIR/.repo/project-objects/$proj.git"
		if [ -d "$d" ] && ! ls "$d"/objects/pack/pack-*.pack >/dev/null 2>&1; then
			say "clearing $proj: only failed tmp packs, no usable pack -> next fetch will be shallow"
			rm -rf "$d"
		fi
	done

	# then try each giant on its own, shallow, with retries
	for proj in $GIANTS; do
		# path inside the source tree: the platform/ prefix is stripped by convention
		wt="$FOX_DIR/${proj#platform/}"
		g="$FOX_DIR/.repo/projects/${proj#platform/}.git"
		# Clear the work side BEFORE the first attempt too.  repo only passes
		# --depth=1 to a project it considers new; as soon as the work git-dir
		# exists it silently fetches FULL history instead (see BUILD-STATUS.md
		# S2), which is exactly the 10-20 GB transfer that keeps dying.
		case "$wt" in
		"$FOX_DIR"/prebuilts/*)
			if [ -e "$g" ] || [ -e "$wt" ]; then
				say "clearing the work side of $proj so every attempt fetches shallow"
				rm -rf "$wt" "$g"
			fi
			;;
		esac
		find "$FOX_DIR/.repo/project-objects/$proj.git" -name 'tmp_pack_*' -delete 2>/dev/null
		for attempt in 1 2 3 4 5 6 7 8 9; do
			[ -d "$FOX_DIR/.repo" ] || return 0
			# These multi-GB transfers die intermittently on any single host with
			# "RPC failed; curl 56 GnuTLS recv error (-9)", so rotate the AOSP
			# mirror instead of retrying the same one forever.
			case $(( (attempt - 1) % 3 )) in
			0) mir="https://mirrors.tuna.tsinghua.edu.cn/git/AOSP" ;;
			1) mir="https://mirrors.ustc.edu.cn/aosp" ;;
			2) mir="https://mirrors.bfsu.edu.cn/git/AOSP" ;;
			esac
			git config --global url."$mir/".insteadOf "https://android.googlesource.com/" 2>/dev/null
			say "targeted shallow sync of $proj (attempt $attempt, mirror $mir)"
			( cd "$FOX_DIR" && repo sync -j1 --force-sync -c --no-clone-bundle --no-tags "$proj" ) && break
			say "  $proj attempt $attempt failed"
			clear_locks
			# do not let the object dir fill up with failed tmp packs
			find "$FOX_DIR/.repo/project-objects/$proj.git" -name 'tmp_pack_*' -delete 2>/dev/null
			# A checkout interrupted mid-way leaves an index that disagrees with
			# the working tree (thousands of staged deletions) and no later
			# checkout can ever converge; start that project over instead.
			if [ "$attempt" -ge 2 ]; then
				case "$wt" in
				"$FOX_DIR"/prebuilts/*)
					say "  wiping the half-checked-out state of $proj (worktree + work git-dir)"
					rm -rf "$wt" "$g"
					;;
				*)
					say "  refusing to wipe $wt: unexpected path"
					;;
				esac
			fi
			sleep 15
		done
	done
}

if [ -f "$STAMP" ] && [ -f "$FOX_DIR/bootable/recovery/orangefox.mk" ]; then
	say "sync+patches already recorded complete ($STAMP) -- skipping the sync phase"
else
	SYNC_OK=0
	ATTEMPT=1
	while [ "$ATTEMPT" -le 12 ]; do
		say "---- sync phase attempt $ATTEMPT/12"
		repair_giants
		if "$TREE/scripts/fox-sync.sh" "$FOX_DIR"; then
			SYNC_OK=1
			touch "$STAMP"
			say "sync phase OK -- stamp written"
			break
		fi
		say "sync phase attempt $ATTEMPT failed"
		ATTEMPT=$((ATTEMPT + 1))
		sleep 30
	done
	if [ "$SYNC_OK" != 1 ]; then
		say "sync phase failed after 12 attempts -- exiting non-zero so systemd retries"
		exit 1
	fi
fi

# ---------------------------------------------------------------- reclaim junk
if ! pgrep -f "$HEAVY" >/dev/null 2>&1; then
	FOUND=$(find "$FOX_DIR/.repo/project-objects" -name 'tmp_pack_*' 2>/dev/null | wc -l)
	if [ "$FOUND" -gt 0 ]; then
		say "reclaiming $FOUND leftover tmp_pack files"
		find "$FOX_DIR/.repo/project-objects" -name 'tmp_pack_*' -delete 2>/dev/null
		df -h "$HOME_DIR" | tail -1
	fi
fi

# ---------------------------------------------------------------- build phase
say "---- build: build-local.sh --skip-sync --jobs $JOBS"
set +e
"$TREE/scripts/build-local.sh" --fox-dir "$FOX_DIR" --jobs "$JOBS" --skip-sync
RC=$?
set -e
if [ "$RC" != 0 ]; then
	say "build failed (exit $RC) -- exiting non-zero so systemd retries"
	exit "$RC"
fi

if [ ! -f "$DIST/boot.img" ]; then
	say "build reported success but $DIST/boot.img is missing -- failing so systemd retries"
	exit 1
fi

say "===== BUILD OK ====="
ls -l "$DIST"
sha256sum "$DIST"/*
say "boot it without flashing anything:  fastboot boot boot.img"
say "===== mars-build end ====="
