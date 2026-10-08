#!/usr/bin/env bash
#
# Download the artifacts of a finished CI run and publish them as a GitHub
# pre-release, so the images can be fetched with a plain `curl -L` / browser.
#
# Usage:
#   GITHUB_TOKEN=... ./scripts/publish-release.sh <run_id> [tag]
#
# Defaults: tag = recovery-test, repo = S0SL/twrp_mars.
#
# Two things this script is careful about:
#   * the artifact download endpoint answers 302 to a *signed* URL on
#     objects.githubusercontent.com.  Sending the Authorization header to that
#     target makes it fail (403), so the redirect is resolved first and the
#     signed URL is then fetched WITHOUT the header.
#   * re-running must be idempotent: an existing release for the tag is reused
#     and existing assets are replaced.
#
set -euo pipefail

RUN_ID="${1:?usage: publish-release.sh <run_id> [tag]}"
TAG="${2:-recovery-test}"
REPO="${REPO:-S0SL/twrp_mars}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is not set}"

API="https://api.github.com/repos/$REPO"
UPLOADS="https://uploads.github.com/repos/$REPO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gh() { curl -sS -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

echo "== run $RUN_ID =="
CONC=$(gh "$API/actions/runs/$RUN_ID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("conclusion") or d.get("status"))')
echo "   conclusion: $CONC"
[ "$CONC" = "success" ] || { echo "ERROR: refusing to publish a run whose conclusion is '$CONC'" >&2; exit 1; }

echo "== artifacts =="
gh "$API/actions/runs/$RUN_ID/artifacts" > "$WORK/artifacts.json"
python3 - "$WORK/artifacts.json" > "$WORK/list.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for a in d.get("artifacts", []):
    if a.get("expired"): continue
    print(f"{a['id']}\t{a['name']}")
PY
cat "$WORK/list.txt"
[ -s "$WORK/list.txt" ] || { echo "ERROR: run has no artifacts" >&2; exit 1; }

mkdir -p "$WORK/dl"
while IFS=$'\t' read -r id name; do
	# Only the image artifact matters for flashing; the log artifact is kept in CI.
	case "$name" in
		build-log-*) echo "-- skipping $name (log only)"; continue ;;
	esac
	echo "-- $name"
	# Resolve the 302 by hand: the signed URL must not carry the token.
	LOC=$(curl -sS -o /dev/null -D - -H "Authorization: token $TOKEN" \
		"$API/actions/artifacts/$id/zip" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
	[ -n "$LOC" ] || { echo "ERROR: no redirect for artifact $id" >&2; exit 1; }
	curl -fsSL -o "$WORK/dl/$name.zip" "$LOC"
	mkdir -p "$WORK/dl/$name"
	unzip -q -o "$WORK/dl/$name.zip" -d "$WORK/dl/$name"
	rm -f "$WORK/dl/$name.zip"
done < "$WORK/list.txt"

echo "== collected files =="
find "$WORK/dl" -type f -printf '%s\t%p\n' | sort -n

echo "== release $TAG =="
REL_ID=$(gh "$API/releases/tags/$TAG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$REL_ID" ]; then
	BODY=$(cat <<EOF
Unofficial OrangeFox (fox_14.1) recovery for the Xiaomi Mi 11 Pro (mars),
built into \`boot.img\` (mars has no recovery partition).

* CI run: https://github.com/$REPO/actions/runs/$RUN_ID
* flavours: \`fastboot boot <img>\` first, \`fastboot flash boot <img>\` only
  once it has been verified to boot.
* nothing here was flashed or tested by CI; flashing is the user's call.
EOF
)
	gh -X POST "$API/releases" \
		-d "$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"mars recovery test builds ("+sys.argv[1]+")","body":sys.argv[2],"prerelease":True,"draft":False}))' "$TAG" "$BODY")" \
		> "$WORK/release.json"
	REL_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/release.json")
	echo "   created release id $REL_ID"
else
	echo "   reusing release id $REL_ID"
fi

echo "== uploading assets =="
for f in $(find "$WORK/dl" -type f | sort); do
	base="$(basename "$f")"
	# Replace an existing asset with the same name.
	OLD=$(gh "$API/releases/$REL_ID/assets" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    if a["name"] == sys.argv[1]: print(a["id"])
' "$base")
	if [ -n "$OLD" ]; then gh -X DELETE "$API/releases/assets/$OLD" >/dev/null; fi
	curl -sS -X POST -H "Authorization: token $TOKEN" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$f" \
		"$UPLOADS/releases/$REL_ID/assets?name=$base" \
		| python3 -c 'import json,sys; d=json.load(sys.stdin); print("   ", d.get("name"), d.get("browser_download_url") or d.get("message"))'
done

echo "== done =="
echo "https://github.com/$REPO/releases/tag/$TAG"
