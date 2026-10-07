# ffmpeg-build

Static `ffmpeg` and `ffprobe` binaries, built from the signed FFmpeg source
by a public workflow, for Linux, macOS and Windows.

The only things trusted are the FFmpeg release signature and this repository's
workflow. No third-party binaries go in, and nothing that ships in a release is
built anywhere else.

## Downloads

Every [release](../../releases) is named after the FFmpeg version it contains
and has two variants for each target:

| Variant | What it contains |
|---|---|
| `slim` | Only what an audio ingest pipeline needs. Reads MP2, MP3, FLAC, WAV/PCM, Opus (Ogg, WebM), AAC (MP4, ADTS), JPEG, PNG and the image formats used as cover art. Writes MP3 (LAME), PCM, JPEG, PNG and stream copies of the formats above. Filters: `ebur128`, `scale`, `aresample`. **No network protocols at all.** |
| `full` | Every decoder, encoder, format, filter and protocol that ships with FFmpeg itself, plus LAME for MP3 encoding. No other external libraries. |

| Target | Built on |
|---|---|
| `linux-x64`, `linux-arm64` | native runners, inside Alpine (musl, fully static) |
| `linux-x86` | x64 runner, 32-bit Alpine container |
| `linux-armv7` | arm64 runner, 32-bit ARM Alpine container (runs natively) |
| `darwin-arm64` | Apple Silicon runner, macOS 13 or later |
| `darwin-x64` | cross-compiled on Apple Silicon, tested under Rosetta 2 |
| `windows-x64`, `windows-x86` | cross-compiled with mingw-w64, tested on Windows |

Each target comes as single gzipped binaries (`ffmpeg-slim-linux-x64.gz`,
`ffprobe-slim-linux-x64.gz`) for scripts, and as one archive with both binaries
and their build info for people.

## Verifying a download

```sh
# Release files
sha256sum -c --ignore-missing SHA256SUMS

# Provenance: built by this repository's release workflow, from this commit
gh attestation verify ffmpeg-slim-linux-x64.gz --repo eli4n/ffmpeg-build

# The unpacked binary has its own checksum and attestation
gunzip ffmpeg-slim-linux-x64.gz
grep ' ffmpeg-slim-linux-x64$' SHA256SUMS-binaries | sha256sum -c
```

Pin the SHA-256 of the binary you use, not the release name.

## How a release is built

1. **Sources** ([`fetch-sources.sh`](fetch-sources.sh)) are downloaded once per
   release and verified before anything else runs:
   - FFmpeg: PGP signature by the FFmpeg release key
     `FCF986EA15E6E293A5644F10B4322F04D67658D8` ([`ffmpeg-devel.asc`](ffmpeg-devel.asc),
     fingerprint as published on [ffmpeg.org](https://ffmpeg.org/download.html#releases)).
   - LAME and zlib: pinned SHA-256 in [`sources.env`](sources.env), cross-checked
     against Alpine's package recipes.
2. **Builds** ([`build.sh`](build.sh)) use exactly those files. `--disable-autodetect`
   keeps anything on the build machine from slipping into a binary; what is
   inside is listed in the script and in `buildinfo.txt`.
3. **Tests** ([`test.sh`](test.sh)) run every binary against
   [`test/fixtures`](test/fixtures): decoding, probing, stream copy, MP3
   encoding, loudness measurement, image scaling. For `slim` they also check
   that Vorbis, `http` and remote playlists are rejected. Linux binaries are
   tested in Debian rather than the Alpine container they were built in.
4. **Release**: checksums, a build provenance attestation for every file and
   every unpacked binary, and the exact sources used, so the binaries can always
   be rebuilt.

Third-party actions and container images are pinned by commit and digest.

## Cutting a release

Push a tag named after an FFmpeg release, or start the *Release* workflow by
hand with that version:

```sh
git tag 9.0.2 && git push origin 9.0.2
```

A release is built once. If it exists, the workflow stops. To rebuild the same
FFmpeg version after changing the recipe, use a suffix: `9.0.2-r2`.

To build locally:

```sh
./fetch-sources.sh 9.0.2 sources
./build.sh sources slim darwin-arm64 out     # on a Mac
./test.sh out slim
```

Linux targets build inside `alpine` (see the workflow for the exact image and
packages).

## Licenses

The scripts in this repository are MIT licensed ([`LICENSE`](LICENSE)).

The binaries are built without `--enable-gpl` and `--enable-nonfree` and are
covered by the [LGPL 2.1 or later](https://ffmpeg.org/legal.html) (FFmpeg),
the LGPL 2.0 or later (LAME) and the zlib license. The corresponding sources are
attached to every release.
