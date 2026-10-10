#!/usr/bin/env bash
# Builds ffmpeg and ffprobe from the sources verified by fetch-sources.sh.
#
# usage: build.sh <source-dir> <slim|full> <target> <output-dir>
#
# Targets:
#   linux-<arch>   inside an Alpine container of that architecture (static, musl)
#                  arch: x64 arm64 x86
#   windows-<arch> inside an x86_64 Alpine container with mingw-w64 (cross build)
#                  arch: x64 x86
#   darwin-arm64   on an Apple Silicon Mac
#   darwin-x64     on an Apple Silicon Mac (cross build)
set -euo pipefail

SRC=$(cd "$1" && pwd)
VARIANT=$2
TARGET=$3
mkdir -p "$4"
OUT=$(cd "$4" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=sources.env
. "$HERE/sources.env"

FFMPEG_TAR=$(cd "$SRC" && ls ffmpeg-*.tar.xz)
FFMPEG_VERSION=${FFMPEG_TAR#ffmpeg-}
FFMPEG_VERSION=${FFMPEG_VERSION%.tar.xz}

JOBS=$(getconf _NPROCESSORS_ONLN)
# A fixed path rather than mktemp: it ends up in `ffmpeg -version` (the
# configure line), and neither a random nor a local user path belongs there.
WORK=/tmp/ffmpeg-build/$VARIANT-$TARGET
rm -rf "$WORK"
mkdir -p "$WORK"
PREFIX=$WORK/prefix
trap 'rm -rf "$WORK"' EXIT

die() {
	echo "build.sh: $*" >&2
	exit 1
}

# --- Target ----------------------------------------------------------------
# Linux builds run inside a container of the target architecture. The check
# stops a wrongly chosen container from quietly producing a binary for the
# wrong architecture.
alpine_arch() {
	[ -f /etc/alpine-release ] || die "$TARGET is built inside an Alpine container"
	apk --print-arch
}

CROSS_PREFIX=
HOST=
ARCH_FLAGS=
FF_TARGET=()
FF_LDFLAGS=
ZLIB=source
EXE=

case $TARGET in
linux-*)
	case ${TARGET#linux-} in
	x64) want=x86_64 ;;
	arm64) want=aarch64 ;;
	x86) want=x86 ;;
	*) die "unknown target $TARGET" ;;
	esac
	[ "$(alpine_arch)" = "$want" ] || die "$TARGET needs a $want container, running on $(alpine_arch)"
	HOST=$(cc -dumpmachine)
	# musl gives every new thread a 128 KiB stack unless the binary asks for
	# more; glibc gives 8 MiB. ffmpeg runs each demuxer, decoder and muxer in a
	# thread of its own, and with 128 KiB the MPEG-TS demuxer crashed (SIGSEGV)
	# on an ordinary AAC-in-TS file. Ask for what glibc would give.
	STACK="-Wl,-z,stack-size=8388608"
	FF_LDFLAGS="-static $STACK"
	# FFmpeg's 32-bit x86 assembly is not position independent, so a static PIE
	# (Alpine's default) ends up with text relocations. Every other target
	# stays a static PIE.
	if [ "$TARGET" = linux-x86 ]; then
		ARCH_FLAGS="-fno-pie"
		FF_LDFLAGS="-static -no-pie $STACK"
	fi
	;;
windows-x64 | windows-x86)
	[ "$(alpine_arch)" = x86_64 ] || die "$TARGET is built inside an x86_64 container"
	if [ "$TARGET" = windows-x64 ]; then
		HOST=x86_64-w64-mingw32
		FF_TARGET=(--arch=x86_64)
	else
		HOST=i686-w64-mingw32
		FF_TARGET=(--arch=x86)
	fi
	CROSS_PREFIX=$HOST-
	FF_TARGET+=(--enable-cross-compile --target-os=mingw32 --cross-prefix=$CROSS_PREFIX)
	FF_LDFLAGS=-static
	EXE=.exe
	;;
darwin-arm64 | darwin-x64)
	[ "$(uname -s)" = Darwin ] || die "$TARGET is built on macOS"
	export MACOSX_DEPLOYMENT_TARGET=13.0
	ZLIB=system # part of the macOS SDK, for both architectures
	if [ "$TARGET" = darwin-arm64 ]; then
		[ "$(uname -m)" = arm64 ] || die "$TARGET is built on Apple Silicon"
		ARCH_FLAGS="-arch arm64"
		HOST=aarch64-apple-darwin
	else
		ARCH_FLAGS="-arch x86_64"
		HOST=x86_64-apple-darwin
		FF_TARGET=(--enable-cross-compile --arch=x86_64 --target-os=darwin)
	fi
	;;
*) die "unknown target $TARGET" ;;
esac

# LAME's config.sub (2017) does not know "arm64-apple", only the equivalent
# "aarch64-apple".
BUILD=$(cc -dumpmachine | sed 's/^arm64-apple-darwin.*/aarch64-apple-darwin/')

CC_FOR_TARGET="${CROSS_PREFIX}cc"
[ -n "$CROSS_PREFIX" ] && CC_FOR_TARGET="${CROSS_PREFIX}gcc"
[ "${TARGET%%-*}" = darwin ] && CC_FOR_TARGET="clang $ARCH_FLAGS"

# --- zlib (PNG, compressed container headers) -------------------------------
if [ "$ZLIB" = source ]; then
	tar -xzf "$SRC/zlib-$ZLIB_VERSION.tar.gz" -C "$WORK"
	(
		cd "$WORK/zlib-$ZLIB_VERSION"
		if [ -n "$EXE" ]; then
			make -f win32/Makefile.gcc -j"$JOBS" PREFIX=$CROSS_PREFIX libz.a
			mkdir -p "$PREFIX/lib" "$PREFIX/include"
			cp libz.a "$PREFIX/lib/"
			cp zlib.h zconf.h "$PREFIX/include/"
		else
			CC=$CC_FOR_TARGET CFLAGS="-O2 -fPIC" ./configure --static --prefix="$PREFIX"
			make -j"$JOBS" install
		fi
	)
fi

# --- LAME (MP3 encoder) ----------------------------------------------------
# Without the frontend and without its own decoder: only libmp3lame is needed,
# and ffmpeg feeds it PCM that ffmpeg decoded itself.
#
# LAME 3.100 calls ID3 functions it never declares. Compilers that default to
# C23 reject that; Homebrew makes the same exception.
tar -xzf "$SRC/lame-$LAME_VERSION.tar.gz" -C "$WORK"
(
	cd "$WORK/lame-$LAME_VERSION"
	CC=$CC_FOR_TARGET CFLAGS="-O2 -Wno-implicit-function-declaration" ac_cv_prog_cc_c23=no \
		./configure --prefix="$PREFIX" --host="$HOST" --build="$BUILD" \
		--disable-shared --enable-static --disable-frontend --disable-decoder \
		--disable-gtktest --disable-dependency-tracking
	make -j"$JOBS" install
)

# --- FFmpeg ----------------------------------------------------------------
COMMON=(
	--prefix="$PREFIX"
	# bash 3.2 (macOS) treats an empty array as unset under `set -u`
	${FF_TARGET[@]+"${FF_TARGET[@]}"}
	--extra-cflags="-I$PREFIX/include $ARCH_FLAGS"
	--extra-ldflags="-L$PREFIX/lib $ARCH_FLAGS $FF_LDFLAGS"
	--pkg-config-flags=--static
	--extra-version="$VARIANT"
	# Pull in nothing from the build machine automatically: whatever is inside
	# the binary is listed here and nowhere else.
	--disable-autodetect
	--disable-doc --disable-ffplay --disable-debug
	--enable-zlib --enable-libmp3lame
)

# Just what an audio ingest pipeline needs: MP2, MP3, FLAC, WAV/PCM, Opus in
# Ogg/WebM, AAC in MP4/ADTS; JPEG/PNG and the image formats found as cover art
# inside audio files. No networking, so no playlist can pull in a URL.
SLIM=(
	--disable-everything --disable-network --disable-avdevice
	--enable-protocol=file,pipe
	# mpegts: broadcast recordings (AAC/MP2 in TS). apng: so an animated PNG is
	# recognised as such instead of being read as a still PNG.
	--enable-demuxer=mp3,flac,wav,ogg,matroska,mov,aac,mpegts,gif,apng,image2,image_jpeg_pipe,image_png_pipe,image_bmp_pipe,image_gif_pipe
	--enable-decoder=mp2,mp2float,mp3,mp3float,flac,opus,aac,aac_fixed,pcm_*,mjpeg,png,bmp,gif
	--enable-parser=mpegaudio,flac,aac,opus,png,mjpeg,bmp,gif
	# wrapped_avframe: the default video encoder of "-f null" when an audio
	# file carries cover art.
	--enable-encoder=libmp3lame,pcm_s16le,mjpeg,png,wrapped_avframe
	--enable-muxer=mp3,mp2,flac,wav,ogg,webm,matroska,mov,mp4,ipod,adts,null,pcm_s16le,image2
	--enable-filter=ebur128,scale,aresample,aformat,anull,null,format
	--enable-bsf=aac_adtstoasc
)

case $VARIANT in
slim) FLAGS=("${COMMON[@]}" "${SLIM[@]}") ;;
full) FLAGS=("${COMMON[@]}") ;;
*) die "unknown variant $VARIANT" ;;
esac

tar -xJf "$SRC/$FFMPEG_TAR" -C "$WORK"
(
	cd "$WORK/ffmpeg-$FFMPEG_VERSION"
	./configure "${FLAGS[@]}" || {
		tail -40 ffbuild/config.log >&2
		exit 1
	}
	make -j"$JOBS"
	cp "ffmpeg$EXE" "ffprobe$EXE" "$OUT/"
	{
		echo "ffmpeg $FFMPEG_VERSION ($VARIANT, $TARGET)"
		echo "lame $LAME_VERSION, zlib $([ "$ZLIB" = source ] && echo "$ZLIB_VERSION" || echo "macOS SDK")"
		echo "compiler: $($CC_FOR_TARGET --version | head -1)"
		echo "configure: $(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h)"
	} >"$OUT/buildinfo.txt"
)
cat "$OUT/buildinfo.txt"
