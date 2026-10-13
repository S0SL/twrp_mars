#!/usr/bin/env bash
# Apply the build-tree patches this device tree depends on.  Idempotent: safe to
# run on every build (scripts/build-local.sh calls it before the preflight).
#
# Why this file exists: the v4.5/v4.6/v4.9 fixes to AOSP sources lived only in the
# build server's tree, so a fresh tree could not reproduce the released images.
set -uo pipefail
FOX="${1:-$HOME/fox_14.1}"
[ -d "$FOX" ] || { echo "apply-patches: no build tree at $FOX"; exit 0; }

python3 - "$FOX" <<'PY'
import io, os, sys
FOX = sys.argv[1]
changed = []

def patch(rel, pairs, marker):
    p = os.path.join(FOX, rel)
    if not os.path.exists(p):
        print('   skip   %s (missing)' % rel); return
    s = io.open(p, encoding='utf-8', errors='surrogateescape').read()
    if marker in s:
        print('   ok     %s (already patched)' % rel); return
    for old, new in pairs:
        if old not in s:
            print('   WARN   %s: pattern not found, patch skipped' % rel); return
        s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    changed.append(rel); print('   patch  %s' % rel)

# ---------------------------------------------------------------- Decrypt.cpp
# v4.5/v4.6: the gatekeeper verify() call sites actually executed on this device
# are the ones in Decrypt_User_Synth_Pass()'s "using secdis to decrypt spblob"
# branch.  Pass a random challenge there (and in the legacy branch, kept for
# completeness), and prefer /metadata/password_slots for the spblob slots.
dec_legacy_old = '\t\t\t\t\tgk_device->verify(fakeUid(user_id), 0 /* challenge */,'
dec_legacy_new = '''\t\t\t\t\t// v4.6 PATCH: random challenge (see the HIDL site below)
\t\t\t\t\tuint64_t gk_challenge = 0;
\t\t\t\t\tint gk_urandom = open("/dev/urandom", O_RDONLY);
\t\t\t\t\tif (gk_urandom >= 0) {
\t\t\t\t\t\t(void)read(gk_urandom, &gk_challenge, sizeof(gk_challenge));
\t\t\t\t\t\tclose(gk_urandom);
\t\t\t\t\t}
\t\t\t\t\tif (gk_challenge == 0)
\t\t\t\t\t\tgk_challenge = 1;
\t\t\t\t\tandroid::hardware::Return<void> hwRet =
\t\t\t\t\t\tgk_device->verify(fakeUid(user_id), gk_challenge,'''
dec_aidl_old = '\t\t\t\tauto result = aidl_gk_device->verify(fakeUid(user_id), 0 /* challenge */, pwd_handle_hidl, gk_pwd_token_hidl, &rsp);'
dec_aidl_new = '''\t\t\t\t// v4.6 PATCH (AIDL path)
\t\t\t\tuint64_t gk_challenge_aidl = 0;
\t\t\t\tint gk_urandom_aidl = open("/dev/urandom", O_RDONLY);
\t\t\t\tif (gk_urandom_aidl >= 0) { (void)read(gk_urandom_aidl, &gk_challenge_aidl, sizeof(gk_challenge_aidl)); close(gk_urandom_aidl); }
\t\t\t\tif (gk_challenge_aidl == 0) gk_challenge_aidl = 1;
\t\t\t\tauto result = aidl_gk_device->verify(fakeUid(user_id), gk_challenge_aidl, pwd_handle_hidl, gk_pwd_token_hidl, &rsp);'''
dec_sp_old = '\tsprintf(spblob_path_char, "/data/system_de/%d/spblob/", user_id);'
dec_sp_new = dec_sp_old + '''
\t// v4.5 PATCH: Android 12+ keeps the synthetic password slots on /metadata when
\t// /data is metadata-encrypted (keydirectory=/metadata/vold/...).
\tif (access(spblob_path_char, F_OK) != 0 && access("/metadata/password_slots/", F_OK) == 0) {
\t\tsnprintf(spblob_path_char, sizeof(spblob_path_char), "/metadata/password_slots/");
\t}'''
dec_stat_old = 'if (stat("/data/system_de/0/spblob", &st) == 0) {'
dec_stat_new = 'if (stat("/data/system_de/0/spblob", &st) == 0 || access("/metadata/password_slots/", F_OK) == 0) {'
# the HIDL site inside Decrypt_User_Synth_Pass needs the same treatment as the
# legacy site, so patch by unique context instead of by indentation alone
p = os.path.join(FOX, 'system/vold/Decrypt.cpp')
if os.path.exists(p):
    s = io.open(p, encoding='utf-8', errors='surrogateescape').read()
    if 'gk_challenge' not in s:
        s2 = s.replace(dec_legacy_old, dec_legacy_new, 1)
        if s2 != s:
            s = s2
        else:
            # no legacy site: patch the synth one (HIDL) directly
            old = '\t\t\t\t\tgk_device->verify(fakeUid(user_id), 0 /* challenge */,'
            new = '''\t\t\t\t\t// v4.6 PATCH: random challenge
\t\t\t\t\tuint64_t gk_challenge = 0;
\t\t\t\t\tint gk_urandom = open("/dev/urandom", O_RDONLY);
\t\t\t\t\tif (gk_urandom >= 0) { (void)read(gk_urandom, &gk_challenge, sizeof(gk_challenge)); close(gk_urandom); }
\t\t\t\t\tif (gk_challenge == 0) gk_challenge = 1;
\t\t\t\t\tgk_device->verify(fakeUid(user_id), gk_challenge,'''
            s = s.replace(old, new, 1)
        s = s.replace(dec_aidl_old, dec_aidl_new, 1)
        io.open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
        changed.append('system/vold/Decrypt.cpp'); print('   patch  system/vold/Decrypt.cpp (challenge)')
    else:
        print('   ok     system/vold/Decrypt.cpp (challenge already patched)')
    s = io.open(p, encoding='utf-8', errors='surrogateescape').read()
    if '/metadata/password_slots' not in s:
        s = s.replace(dec_sp_old, dec_sp_new, 1).replace(dec_stat_old, dec_stat_new, 1)
        io.open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
        changed.append('system/vold/Decrypt.cpp'); print('   patch  system/vold/Decrypt.cpp (spblob path)')
    else:
        print('   ok     system/vold/Decrypt.cpp (spblob path already patched)')

# ----------------------------------------------------------------- gui/gui.cpp
# v5: drag notices were only delivered when the frame budget expired, and while
# input was pending that budget was 500 ms (gui.cpp loopTimer), so sliders and
# drag gestures updated ~2 times per second.  Deliver once per frame instead.
patch('gui/gui.cpp', [(
    '\t\tlong timeout = got_event ? 500000000 : (1.0 / TW_FRAMERATE * 1000000000);',
    '''\t\t// v5 PATCH: upstream used a 500 ms budget whenever input was pending, so
\t\t// handleDrag() only ran twice per second and swipes/sliders felt
\t\t// unresponsive.  Always use the frame budget.
\t\tlong timeout = (1.0 / TW_FRAMERATE * 1000000000);''')],
    'v5 PATCH: upstream used a 500 ms budget')

print('apply-patches: %d file(s) changed' % len(set(changed)))
PY
