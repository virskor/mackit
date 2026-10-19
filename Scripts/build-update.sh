#!/bin/bash
# Package the Sparkle automatic update archive and generate the appcast
# Usage: Scripts/build-update.sh
#
# Prerequisite: first build a signed Mackit.app (Scripts/build-dmg.sh or
# Scripts/build-app.sh). This script packs the .app into an update archive,
# signs it with the EdDSA private key, and hands it to Sparkle's
# generate_appcast to generate / append to appcast.xml.
#
# The archive format is fixed at .tar.bz2: Sparkle's runtime unpacking table
# only accepts zip / tar / tar.gz / tar.bz2 / tar.xz / .aar, and does not
# include .tar.zst — picking the wrong format gives "download succeeded but
# extraction failed". bz2 is supported by the tar bundled with macOS, so no
# external tool is needed.
#
# Security model (Sparkle's hard requirements, none of which can be omitted):
#   1. Every update archive carries an EdDSA signature — the private key stays
#      only on the release machine / CI, and the public key is distributed with
#      the app's Info.plist (SUPublicEDKey);
#   2. The app inside the update archive and the host are signed with the same
#      Developer ID identity — Sparkle's XPC service verifies that the Team IDs
#      match on both ends;
#   3. The feed and update archives use HTTPS.
# The host app is notarized, and the update archive is downloaded to disk by
# the app itself without going through browser quarantine, so Gatekeeper does
# not perform a first assessment on it; the update archive itself is therefore
# not required to be notarized — to align with the DMG's full notarization
# flow, see MACKIT_NOTARIZE_UPDATE below.
#
# Environment variables:
#   MACKIT_APP_PATH           Path of the .app to package, defaulting to
#                             Mackit.app at the repository root. Use it when the
#                             build product lives elsewhere in CI.
#   MACKIT_ED_KEY_FILE        EdDSA private key file (the --ed-key-file of
#                             generate_appcast / sign_update). When unset, it is
#                             read from the login keychain (the default storage
#                             location of generate_keys).
#   MACKIT_DOWNLOAD_URL_PREFIX   URL prefix where the update archive is hosted.
#                             Each enclosure's address in the appcast =
#                             prefix + archive file name.
#                             For GitHub Release assets use:
#                             https://github.com/<owner>/<repo>/releases/download/<tag>/
#   MACKIT_UPDATES_DIR        Output directory for the appcast and update
#                             archives, defaulting to dist/updates.
#                             Historical archives must always be kept: they will
#                             be needed for delta updates later.
#   MACKIT_NOTES_FILE         Release notes for this version (.html / .md / .txt).
#                             Copied into the output directory under the
#                             archive's base name, to be embedded in the appcast
#                             by generate_appcast. When omitted there are no
#                             release notes, only the version number.
#   MACKIT_LINK               "Learn more" link in the update window, defaulting
#                             to the official website.
#   MACKIT_MAXIMUM_VERSIONS   Number of historical versions to keep per system
#                             threshold branch in the appcast, default 0 = keep
#                             all (old versions remain available for explicit
#                             reinstallation).
#   MACKIT_SPARKLE_VERSION    Sparkle command-line tool version, default 2.10.0.
#   MACKIT_SPARKLE_TOOLS_DIR  Tool cache directory, default .build/sparkle-tools.
#
# Output: $MACKIT_UPDATES_DIR/appcast.xml and Mackit-<version>.tar.bz2.
# Both must be uploaded to the same HTTPS location (the prefix points at it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MACKIT_APP_PATH:-$ROOT/Mackit.app}"
DIST="$ROOT/dist"
UPDATES_DIR="${MACKIT_UPDATES_DIR:-$DIST/updates}"
SPARKLE_VERSION="${MACKIT_SPARKLE_VERSION:-2.10.0}"
TOOLS_DIR="${MACKIT_SPARKLE_TOOLS_DIR:-$ROOT/.build/sparkle-tools}"

if [ ! -d "$APP" ]; then
    echo "找不到 $APP，先构建 Mackit.app。" >&2
    exit 1
fi

# The version number is taken from the built Info.plist (same source as build-dmg.sh).
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "无法从 $APP/Contents/Info.plist 读取版本号" >&2
    exit 1
fi
ARCHIVE="$UPDATES_DIR/Mackit-$VERSION.tar.bz2"
echo "==> 版本 ${VERSION}（构建 ${BUILD_NUMBER:-?}），目标 ${ARCHIVE}"

# ---------- 1. Sparkle command-line tools ----------
# Download only when missing: generate_appcast / sign_update / generate_keys
# are universal binaries that run on both arm64 and x86_64. The tools live
# under bin/ in the tarball; after extracting to TOOLS_DIR, reference
# $TOOLS_DIR/bin/.
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$TOOLS_DIR"
if [ ! -x "$BIN_DIR/generate_appcast" ]; then
    echo "==> 下载 Sparkle 命令行工具 ${SPARKLE_VERSION}"
    TARBALL="$TOOLS_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fL -o "$TARBALL" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    tar -xzf "$TARBALL" -C "$TOOLS_DIR" \
        ./bin/generate_appcast ./bin/sign_update ./bin/generate_keys
    rm -f "$TARBALL"
fi
GENERATE_APPCAST="$BIN_DIR/generate_appcast"

# ---------- 2. Verify the app signature ----------
# The app inside the update archive must be signed with the same identity as
# the host for Sparkle to accept it. Ad-hoc-signed local builds are packaged as
# usual (for local testing); before distributing, make sure it is Developer ID.
echo "==> 校验应用签名"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
if echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
    echo "    Developer ID Application"
else
    echo "    警告：不是 Developer ID Application 签名，只能本机测试更新链路。" >&2
fi

# ---------- 3. Package ----------
# The archive contains only the .app itself at the root (Sparkle's installation
# requirement). Packaging by basename from its directory also holds when
# MACKIT_APP_PATH points elsewhere.
# Extended attributes (signatures live in com.apple.cs.*) are preserved by
# tar's pax format, so copying does not lose the signature.
APP_DIR="$(cd "$(dirname "$APP")" && pwd)"
APP_NAME="$(basename "$APP")"
mkdir -p "$UPDATES_DIR"
echo "==> 打包 ${ARCHIVE}"
rm -f "$ARCHIVE"
tar -cjf "$ARCHIVE" -C "$APP_DIR" "$APP_NAME"

# ---------- 4. Release notes ----------
# generate_appcast looks for the notes file "with the same base name as the
# archive", so copy it under the canonical name first.
if [ -n "${MACKIT_NOTES_FILE:-}" ]; then
    if [ ! -f "$MACKIT_NOTES_FILE" ]; then
        echo "更新说明文件不存在：$MACKIT_NOTES_FILE" >&2
        exit 1
    fi
    NOTES_EXT="${MACKIT_NOTES_FILE##*.}"
    DEST="$UPDATES_DIR/Mackit-$VERSION.$NOTES_EXT"
    # When source and destination are the same file, cp reports "are identical"
    # with a non-zero exit, and set -e would take down the whole script — dying
    # before the appcast is even generated. Resolve the real paths and compare
    # first; if they are the same, skip the copy (the file is already in the
    # output directory, and generate_appcast can still embed it).
    SRC_REAL="$(cd "$(dirname "$MACKIT_NOTES_FILE")" && pwd -P)/$(basename "$MACKIT_NOTES_FILE")"
    DEST_REAL="$(cd "$UPDATES_DIR" && pwd -P)/$(basename "$DEST")"
    if [ "$SRC_REAL" = "$DEST_REAL" ]; then
        echo "==> 更新说明已在输出目录，跳过拷贝：$DEST"
    else
        cp "$MACKIT_NOTES_FILE" "$DEST"
        echo "==> 更新说明：$DEST"
    fi
fi

# ---------- 5. Generate the appcast ----------
# --embed-release-notes embeds the notes in the appcast item's description,
# saving the need to separately host a signed notes file. Without --ed-key-file
# it reads the login keychain.
# maximum-versions defaults to 0 (keep all), so explicitly reinstalling old
# versions is still possible.
APPCAST_ARGS=("$UPDATES_DIR" --embed-release-notes)
if [ -n "${MACKIT_DOWNLOAD_URL_PREFIX:-}" ]; then
    APPCAST_ARGS+=(--download-url-prefix "$MACKIT_DOWNLOAD_URL_PREFIX")
else
    echo "警告：未设置 MACKIT_DOWNLOAD_URL_PREFIX，" >&2
    echo "      enclosure 地址会是本地路径，上传前必须补托管前缀重新生成本步。" >&2
fi
if [ -n "${MACKIT_ED_KEY_FILE:-}" ]; then
    APPCAST_ARGS+=(--ed-key-file "$MACKIT_ED_KEY_FILE")
fi
if [ -n "${MACKIT_LINK:-}" ]; then
    APPCAST_ARGS+=(--link "$MACKIT_LINK")
fi
if [ -n "${MACKIT_MAXIMUM_VERSIONS:-}" ]; then
    APPCAST_ARGS+=(--maximum-versions "$MACKIT_MAXIMUM_VERSIONS")
fi

echo "==> 生成 appcast"
"$GENERATE_APPCAST" "${APPCAST_ARGS[@]}"

# ---------- 6. Self-check ----------
# Recompute the archive's EdDSA signature and compare it with the value
# recorded in the appcast: a mismatch means the archive was modified after the
# appcast was generated (or the version number collided with an old file);
# catch it before uploading.
echo "==> 验签更新归档"
SIGN_ARGS=(-p "$ARCHIVE")
if [ -n "${MACKIT_ED_KEY_FILE:-}" ]; then
    SIGN_ARGS+=(--ed-key-file "$MACKIT_ED_KEY_FILE")
fi
DISK_SIG="$("$BIN_DIR/sign_update" "${SIGN_ARGS[@]}")"
if grep -qF "$DISK_SIG" "$UPDATES_DIR/appcast.xml"; then
    echo "    签名与 appcast 一致"
else
    echo "错误：归档签名与 appcast 记录不一致，不要分发。" >&2
    exit 1
fi

echo
echo "完成：${UPDATES_DIR}/appcast.xml"
echo "      ${ARCHIVE}"
echo
echo "上传到同一个 HTTPS 位置（前缀须为 MACKIT_DOWNLOAD_URL_PREFIX），"
echo "并把 appcast.xml 的地址配进构建："
echo "  MACKIT_UPDATE_FEED_URL=https://.../appcast.xml \\"
echo "  MACKIT_UPDATE_PUBLIC_KEY=<generate_keys 输出的公钥> \\"
echo "  Scripts/build-dmg.sh release"
