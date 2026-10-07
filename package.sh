#!/usr/bin/env bash
# Turns the build artifacts into release assets, checksums and release notes.
#
# usage: package.sh <artifacts-dir> <dist-dir> <tag>
#
# <artifacts-dir> holds one directory per build (bin-<variant>-<target>) with
# ffmpeg, ffprobe and buildinfo.txt, plus "sources" from fetch-sources.sh.
#
# Writes:
#   <dist-dir>/release/                 everything that is attached to the release
#     ffmpeg-<variant>-<target>[.exe].gz  single binaries, for scripts
#     ffprobe-<variant>-<target>[.exe].gz
#     ffmpeg-<tag>-<variant>-<target>.tar.gz|.zip  both binaries + buildinfo
#     ffmpeg-<v>.tar.xz(.asc), lame-*, zlib-*      the exact sources used
#     SHA256SUMS                         every file above
#     SHA256SUMS-binaries                every binary as it is after gunzip
#   <dist-dir>/NOTES.md                  release notes
set -euo pipefail

ART=$(cd "$1" && pwd)
mkdir -p "$2/release"
DIST=$(cd "$2" && pwd)
REL=$DIST/release
TAG=$3
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=sources.env
. "$HERE/sources.env"

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

: >"$DIST/binaries.sha256"
builds=()
for dir in "$ART"/bin-*; do
	build=${dir##*/bin-} # <variant>-<target>
	builds+=("$build")
	exe=
	[ -f "$dir/ffmpeg.exe" ] && exe=.exe
	for tool in ffmpeg ffprobe; do
		name=$tool-$build$exe
		echo "$(sha256_of "$dir/$tool$exe")  $name" >>"$DIST/binaries.sha256"
		gzip -9 -n -c "$dir/$tool$exe" >"$REL/$name.gz"
	done

	bundle=ffmpeg-$TAG-$build
	staging=$DIST/staging/$bundle
	mkdir -p "$staging"
	cp "$dir/ffmpeg$exe" "$dir/ffprobe$exe" "$dir/buildinfo.txt" "$staging/"
	chmod 755 "$staging/ffmpeg$exe" "$staging/ffprobe$exe"
	if [ -n "$exe" ]; then
		(cd "$DIST/staging" && zip -q -r -X "$REL/$bundle.zip" "$bundle")
	else
		tar -C "$DIST/staging" -czf "$REL/$bundle.tar.gz" "$bundle"
	fi
done
[ ${#builds[@]} -gt 0 ] || {
	echo "package.sh: no builds in $ART" >&2
	exit 1
}

cp "$ART"/sources/* "$REL/"

(cd "$REL" && for f in *; do echo "$(sha256_of "$f")  $f"; done) | grep -v '  SHA256SUMS' >"$DIST/release.sha256"
sort -k2 "$DIST/release.sha256" >"$REL/SHA256SUMS"
sort -k2 "$DIST/binaries.sha256" >"$REL/SHA256SUMS-binaries"

# Absolute links in CI, where the repository and the run are known
REPO=${GITHUB_REPOSITORY:-OWNER/REPO}
REPO_URL=${GITHUB_SERVER_URL:-https://github.com}/$REPO
RUN_URL=$REPO_URL/actions/workflows/release.yml
[ -n "${GITHUB_RUN_ID:-}" ] && RUN_URL=$REPO_URL/actions/runs/$GITHUB_RUN_ID

ffmpeg_tar=$(cd "$ART/sources" && ls ffmpeg-*.tar.xz)
{
	echo "FFmpeg ${ffmpeg_tar#ffmpeg-}" | sed 's/\.tar\.xz$//'
	echo
	echo "Built from source by [this workflow run]($RUN_URL)."
	echo "Every asset and every unpacked binary has a [build provenance attestation]($REPO_URL/attestations)."
	echo
	echo "## Sources"
	echo
	echo "| File | SHA-256 | Verified by |"
	echo "|---|---|---|"
	echo "| \`$ffmpeg_tar\` | \`$(sha256_of "$ART/sources/$ffmpeg_tar")\` | PGP signature, key \`$FFMPEG_KEY_FPR\` |"
	echo "| \`lame-$LAME_VERSION.tar.gz\` | \`$LAME_SHA256\` | pinned hash |"
	echo "| \`zlib-$ZLIB_VERSION.tar.gz\` | \`$ZLIB_SHA256\` | pinned hash |"
	echo
	echo "## Builds"
	echo
	echo "| Variant | Target | Compiler |"
	echo "|---|---|---|"
	for build in "${builds[@]}"; do
		echo "| ${build%%-*} | ${build#*-} | $(sed -n 's/^compiler: //p' "$ART/bin-$build/buildinfo.txt") |"
	done
	echo
	echo "**slim**: only MP2, MP3, FLAC, WAV/PCM, Opus (Ogg/WebM), AAC (MP4/ADTS), JPEG/PNG input; MP3, PCM, JPEG/PNG output; no network protocols."
	echo "**full**: every component that ships with FFmpeg itself, plus LAME. No other external libraries."
	echo
	echo "## Verify"
	echo
	echo '```sh'
	echo "sha256sum -c --ignore-missing SHA256SUMS"
	echo "gh attestation verify ffmpeg-slim-linux-x64.gz --repo $REPO"
	echo "gunzip ffmpeg-slim-linux-x64.gz && grep ' ffmpeg-slim-linux-x64\$' SHA256SUMS-binaries | sha256sum -c"
	echo '```'
} >"$DIST/NOTES.md"

# Subjects for the attestation: the release files and the unpacked binaries.
cat "$REL/SHA256SUMS" "$REL/SHA256SUMS-binaries" >"$DIST/attest-subjects.txt"

ls -la "$REL"
