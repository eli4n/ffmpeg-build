#!/usr/bin/env bash
# Downloads the FFmpeg, LAME and zlib sources and verifies them before any build
# touches them. Aborts on the slightest mismatch.
#
# usage: fetch-sources.sh <ffmpeg-version> <destination-dir>
set -euo pipefail

VERSION=$1
DEST=$2
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=sources.env
. "$HERE/sources.env"

mkdir -p "$DEST"
cd "$DEST"

fetch() {
	curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$2" "$1"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

expect_sha256() {
	local got
	got=$(sha256_of "$1")
	if [ "$got" != "$2" ]; then
		echo "$1: SHA-256 is $got, expected $2" >&2
		exit 1
	fi
}

# --- FFmpeg: signature by the pinned release key -----------------------------
ffmpeg_tar=ffmpeg-$VERSION.tar.xz
fetch "https://ffmpeg.org/releases/$ffmpeg_tar" "$ffmpeg_tar"
fetch "https://ffmpeg.org/releases/$ffmpeg_tar.asc" "$ffmpeg_tar.asc"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$HERE/ffmpeg-devel.asc" 2>/dev/null

# VALIDSIG names the primary key in its last field, and that is the only thing
# that counts. Any other key in the keyring, valid or not, is not enough.
status=$(gpg --batch --status-fd 1 --verify "$ffmpeg_tar.asc" "$ffmpeg_tar" 2>/dev/null || true)
signer=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $NF }')
if [ "$signer" != "$FFMPEG_KEY_FPR" ]; then
	echo "$ffmpeg_tar: no valid signature by $FFMPEG_KEY_FPR" >&2
	printf '%s\n' "$status" >&2
	exit 1
fi
echo "$ffmpeg_tar: good signature ($signer), SHA-256 $(sha256_of "$ffmpeg_tar")"

# --- LAME and zlib: pinned hashes ------------------------------------------
lame_tar=lame-$LAME_VERSION.tar.gz
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/$lame_tar" "$lame_tar"
expect_sha256 "$lame_tar" "$LAME_SHA256"
echo "$lame_tar: SHA-256 matches"

zlib_tar=zlib-$ZLIB_VERSION.tar.gz
fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/$zlib_tar" "$zlib_tar"
expect_sha256 "$zlib_tar" "$ZLIB_SHA256"
echo "$zlib_tar: SHA-256 matches"
