#!/usr/bin/env bash
# Creates the files under test/fixtures. Only needed when new formats are
# added; the files are checked in.
#
# Needs an ffmpeg with encoders for every format (libmp3lame, libopus,
# libvorbis, aac, mp2, flac), i.e. precisely not one of the builds from this
# repository.
#
# usage: test/make-fixtures.sh <path-to-a-full-ffmpeg>
set -euo pipefail

FFMPEG=$1
F=$(cd "$(dirname "$0")" && pwd)/fixtures
mkdir -p "$F"

run() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }
tone() { run -f lavfi -i sine=frequency=440:duration=1:sample_rate=44100 -ac 1 "$@"; }

# One second of tone in every format the slim variant has to read
tone -c:a libmp3lame -b:a 64k "$F/tone.mp3"
tone -c:a mp2 -b:a 64k "$F/tone.mp2"
tone -c:a flac "$F/tone.flac"
tone -c:a pcm_s16le "$F/tone-s16.wav"
tone -c:a pcm_s24le "$F/tone-s24.wav"
tone -c:a pcm_f32le "$F/tone-f32.wav"
tone -ar 48000 -c:a libopus -b:a 24k "$F/tone.ogg"
tone -ar 48000 -c:a libopus -b:a 24k "$F/tone.webm"
tone -c:a aac -b:a 48k "$F/tone.m4a"
tone -c:a aac -b:a 48k -f adts "$F/tone.aac"

# Deliberately not in slim: Vorbis
tone -c:a libvorbis -q:a 0 "$F/tone-vorbis.ogg"

# Images, and audio files with embedded cover art
run -f lavfi -i testsrc=size=96x64:duration=1 -frames:v 1 "$F/cover.jpg"
run -f lavfi -i testsrc=size=96x64:duration=1 -frames:v 1 "$F/cover.png"
run -i "$F/tone.mp3" -i "$F/cover.jpg" -map 0:a -map 1:v -c copy -id3v2_version 3 \
	-disposition:v attached_pic "$F/tone-cover.mp3"
run -i "$F/tone.m4a" -i "$F/cover.png" -map 0:a -map 1:v -c copy \
	-disposition:v attached_pic "$F/tone-cover.m4a"

# A playlist that wants to fetch a URL; slim must not be able to open it
printf '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:9/segment.ts\n#EXT-X-ENDLIST\n' >"$F/remote.m3u8"

ls -la "$F"
