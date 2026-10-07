#!/usr/bin/env bash
# Prints the newest release of every FFmpeg branch from <oldest-branch> on, one
# version per line, oldest branch first. Reads https://ffmpeg.org/releases/,
# the directory fetch-sources.sh downloads from.
#
# usage: latest-releases.sh <oldest-branch>     e.g. latest-releases.sh 7.1
set -euo pipefail

OLDEST=$1
[[ "$OLDEST" =~ ^([0-9]+)\.([0-9]+)$ ]] || {
	echo "latest-releases.sh: '$OLDEST' is not a branch like 7.1" >&2
	exit 1
}

curl -fsSL --retry 3 --proto '=https' --tlsv1.2 https://ffmpeg.org/releases/ |
	grep -oE 'href="ffmpeg-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz"' |
	sed -E 's/^href="ffmpeg-//; s/\.tar\.xz"$//' |
	sort -u -V |
	awk -F. -v major="${BASH_REMATCH[1]}" -v minor="${BASH_REMATCH[2]}" '
		# Input is sorted ascending, so the last version seen per branch is
		# its newest.
		$1 > major || ($1 == major && $2 >= minor) { newest[$1 "." $2] = $0 }
		END { for (branch in newest) print newest[branch] }
	' |
	sort -V
