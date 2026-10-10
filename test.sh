#!/usr/bin/env bash
# Checks built binaries against test/fixtures. Runs on Linux, macOS and Git Bash
# on Windows.
#
# usage: test.sh <dir-with-ffmpeg-and-ffprobe> <slim|full>
set -uo pipefail

BIN=$(cd "$1" && pwd)
VARIANT=$2
FX=$(cd "$(dirname "$0")" && pwd)/test/fixtures
EXE=
[ -f "$BIN/ffmpeg.exe" ] && EXE=.exe
FFMPEG=$BIN/ffmpeg$EXE
FFPROBE=$BIN/ffprobe$EXE
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failed=0
check() {
	local name=$1
	shift
	if "$@" >"$TMP/log" 2>&1; then
		echo "ok    $name"
	else
		echo "FAIL  $name"
		tail -5 "$TMP/log" | sed 's/^/      /'
		failed=$((failed + 1))
	fi
}
# Windows binaries write CRLF
probe() { "$FFPROBE" -v error "$@" | tr -d '\r'; }

# The usual way to validate an upload: decoding cleanly means nothing at all
# on stderr.
decodes_cleanly() {
	local err
	err=$("$FFMPEG" -v error -i "$1" -f null - 2>&1) || return 1
	[ -z "$err" ] || {
		echo "$err"
		return 1
	}
}
codec_is() {
	local got
	# MPEG-TS lists each stream twice (under its program and on its own)
	got=$(probe -select_streams "$2:0" -show_entries stream=codec_name -of csv=p=0 "$1" | head -1)
	[ "$got" = "$3" ] || {
		echo "codec $got, expected $3"
		return 1
	}
}
duration_about_one_second() {
	local last
	last=$(probe -select_streams a:0 -show_entries packet=pts_time,duration_time -of csv=p=0 "$1" | grep -v '^$' | tail -1)
	awk -v l="$last" 'BEGIN { split(l, p, ","); d = p[1] + p[2]; if (d < 0.9 || d > 1.2) { print "duration " d; exit 1 } }'
}
strips_metadata() {
	local ext=${1##*.}
	"$FFMPEG" -v error -i "$1" -write_xing 0 -id3v2_version 0 -map 0:a -c:a copy -map_metadata -1 -y "$TMP/stripped.$ext"
}
encodes_mp3() {
	"$FFMPEG" -v error -i "$1" -map 0:a -c:a libmp3lame -ar 44100 -ac 2 -b:a 96k -y "$TMP/out.mp3" &&
		codec_is "$TMP/out.mp3" a mp3
}
measures_loudness() {
	"$FFMPEG" -nostats -i "$1" -af ebur128 -f null - 2>&1 | grep -q 'I:.*LUFS'
}
decodes_to_pcm() {
	local bytes
	bytes=$("$FFMPEG" -v error -i "$1" -f s16le -ac 1 -acodec pcm_s16le -ar 8000 pipe:1 | wc -c)
	[ "$bytes" -gt 14000 ] || {
		echo "only $bytes bytes of PCM"
		return 1
	}
}

# --- Basics ----------------------------------------------------------------
version() { "$1" -version | head -1 | awk '{print $3}'; }
check "ffmpeg and ffprobe report the same version ($(version "$FFMPEG"))" \
	test "$(version "$FFMPEG")" = "$(version "$FFPROBE")"

# --- Audio -----------------------------------------------------------------
for spec in tone.mp3:mp3 tone.mp2:mp2 tone.flac:flac tone-s16.wav:pcm_s16le tone-s24.wav:pcm_s24le \
	tone-f32.wav:pcm_f32le tone.ogg:opus tone.webm:opus tone.m4a:aac tone.aac:aac \
	tone-cover.mp3:mp3 tone-cover.m4a:aac; do
	f=$FX/${spec%%:*}
	name=${spec%%:*}
	check "$name: decodes cleanly" decodes_cleanly "$f"
	check "$name: codec ${spec##*:}" codec_is "$f" a "${spec##*:}"
	check "$name: duration by packet scan" duration_about_one_second "$f"
	check "$name: strip metadata (stream copy)" strips_metadata "$f"
	check "$name: encode to MP3" encodes_mp3 "$f"
	check "$name: loudness (ebur128)" measures_loudness "$f"
	check "$name: PCM for a waveform" decodes_to_pcm "$f"
done

# AAC in MPEG-TS: the backend renames it to .aac and strips into ADTS
f=$FX/tone.ts
check "tone.ts: decodes cleanly" decodes_cleanly "$f"
check "tone.ts: codec aac" codec_is "$f" a aac
check "tone.ts: every packet readable" sh -c "'$FFPROBE' -v error -show_packets '$f' >/dev/null"
check "tone.ts: strip metadata into ADTS" "$FFMPEG" -v error -i "$f" -map 0:a -c:a copy -map_metadata -1 -y "$TMP/stripped.aac"
check "tone.ts: encode to MP3" encodes_mp3 "$f"

# --- Images ----------------------------------------------------------------
for spec in cover.jpg:mjpeg cover.png:png; do
	f=$FX/${spec%%:*}
	name=${spec%%:*}
	check "$name: decodes cleanly" decodes_cleanly "$f"
	check "$name: codec ${spec##*:}" codec_is "$f" v "${spec##*:}"
	check "$name: downscale (scale filter) to JPEG" "$FFMPEG" -v error -i "$f" \
		-vf scale=48:48:force_original_aspect_ratio=decrease:force_divisible_by=2 \
		-frames:v 1 -update 1 -y "$TMP/small.jpg"
	check "$name: downscale (-s) to PNG" "$FFMPEG" -v error -i "$f" -s 48x32 -y "$TMP/small.png"
done
check "animated PNG is recognised as apng" codec_is "$FX/animated.png" v apng
check "cover dimensions via ffprobe" \
	test "$(probe -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$FX/cover.png")" = "96,64"

# --- What the variant must not, or must, be able to do ---------------------
fails() { ! "$@"; }
if [ "$VARIANT" = slim ]; then
	check "slim: rejects Vorbis" fails decodes_cleanly "$FX/tone-vorbis.ogg"
	check "slim: no http protocol" fails "$FFMPEG" -v error -i http://127.0.0.1:9/x.mp3 -f null -
	check "slim: cannot open a playlist that points to a URL" fails "$FFPROBE" -v error "$FX/remote.m3u8"
	check "slim: no network protocols built in" \
		test -z "$("$FFMPEG" -hide_banner -protocols | tr -d '\r' | grep -E -x '\s*(http|https|tcp|udp|rtmp|ftp)')"
else
	check "full: reads Vorbis" decodes_cleanly "$FX/tone-vorbis.ogg"
	check "full: has the http protocol" sh -c "'$FFMPEG' -hide_banner -protocols | tr -d '\r' | grep -q -E -x '\s*http'"
fi

echo
if [ "$failed" -gt 0 ]; then
	echo "$failed checks failed ($VARIANT)"
	exit 1
fi
echo "all checks passed ($VARIANT)"
