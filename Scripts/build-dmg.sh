#!/bin/bash
# Package Mackit-<version>.dmg
# Usage: Scripts/build-dmg.sh [release|debug]
#
# Signing and notarization are both environment-variable switches; the package
# can be built without them, but will only run on this machine.
#
# Environment variables:
#   MACKIT_SIGN_IDENTITY   Same as build-app.sh. Once set to a Developer ID
#                          Application identity: the DMG will be signed and can
#                          enter the notarization flow.
#   MACKIT_NOTARY_PROFILE  notarytool keychain profile name (stored via
#                          notarytool store-credentials; takes priority)
#   MACKIT_API_KEY         Path to the App Store Connect API key .p8 file
#   MACKIT_API_KEY_ID      The Key ID of that key
#   MACKIT_API_ISSUER      The team's Issuer ID (UUID)
#   MACKIT_APPLE_ID        Apple ID (used together with the two below, either
#                          one)
#   MACKIT_APP_PASSWORD    App-specific password
#   MACKIT_TEAM_ID         Developer team ID
#   MACKIT_VERSION / MACKIT_BUILD_NUMBER  Override the version number (same as
#                          build-app.sh)
#   MACKIT_ARCHES         List of architectures to build, default "arm64
#                         x86_64" — a universal binary, so one DMG supports
#                         both Apple silicon and Intel Macs (Intel machines
#                         must be able to upgrade to macOS 14). Set to "arm64"
#                         to produce an Apple silicon-only build.
#   MACKIT_SKIP_BUILD=1    Skip the build and package the existing Mackit.app
#   MACKIT_SKIP_ICON=1     Reuse the existing app icon (same as build-app.sh)
#   MACKIT_NO_LAYOUT=1     Skip the Finder window layout (when there is no GUI)
#   MACKIT_LAYOUT_TIMEOUT  Seconds to wait for Finder automation authorization,
#                          default 60. The first run pops an authorization
#                          dialog; when unattended (CI), the layout is skipped
#                          automatically once the time is up, without affecting
#                          the DMG itself.
#
# Output: dist/Mackit-<version>.dmg and a same-named .sha256
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Mackit.app"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/.build"
VOLUME_NAME="Mackit"

# Wait for the child process to finish, at most timeout seconds; the exit code
# is written to the global WAIT_STATUS. On timeout (already killed) returns 1.
# macOS has no timeout command, and the TCC authorization prompt waits forever
# unless clicked, so unattended builds must not hang here.
WAIT_STATUS=0
wait_bounded() {
    local pid="$1" timeout="$2" waited=0 state
    while :; do
        # Zombie processes still respond to kill -0, so the ps status bit must be checked.
        state="$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]' || true)"
        if [ -z "$state" ] || [ "$state" = "Z" ]; then
            wait "$pid" && WAIT_STATUS=0 || WAIT_STATUS=$?
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# ---------- 1. Build ----------
# Release builds default to a universal binary: Intel Macs are unavoidable
# among recipients, and one package covering both architectures is less work
# than maintaining two DMGs. Development iteration still goes through run.sh
# (native single-architecture, fastest).
MACKIT_ARCHES="${MACKIT_ARCHES:-arm64 x86_64}"

if [ "${MACKIT_SKIP_BUILD:-0}" = "1" ]; then
    echo "==> Skipping build (MACKIT_SKIP_BUILD=1)"
else
    echo "==> Building Mackit.app (${CONFIG})"
    MACKIT_SIGN_IDENTITY="${MACKIT_SIGN_IDENTITY:-}" \
    MACKIT_VERSION="${MACKIT_VERSION:-}" \
    MACKIT_BUILD_NUMBER="${MACKIT_BUILD_NUMBER:-}" \
    MACKIT_SKIP_ICON="${MACKIT_SKIP_ICON:-0}" \
    MACKIT_ARCHES="$MACKIT_ARCHES" \
        "$ROOT/Scripts/build-app.sh" "$CONFIG"
fi

if [ ! -d "$APP" ]; then
    echo "Cannot find $APP" >&2
    exit 1
fi

# ---------- 2. Version ----------
# Take the built Info.plist as the source of truth: build-app.sh has already
# filled it in as "environment variable > git tag > 1.0", so just read it out
# here — this is the version the user ultimately sees.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "Cannot read the version number from $APP/Contents/Info.plist" >&2
    exit 1
fi
DMG="$DIST/Mackit-$VERSION.dmg"
# The braces cannot be omitted: bash 3.2 swallows the non-ASCII bytes following $VAR into the variable name.
echo "==> Version ${VERSION}, target ${DMG}"

# ---------- 3. Verify the app signature and architecture ----------
# Print the actual architecture first: a universal binary should contain both
# x86_64 and arm64; when MACKIT_SKIP_BUILD=1 is used, this line shows the
# architecture actually in the package, avoiding delivering a half-built package.
echo "==> Verifying architecture"
lipo -info "$APP/Contents/MacOS/Mackit" | sed 's/^/    /'

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# The nested resource bundle is only signed separately on the Developer ID path
# (build-app.sh's behavior); on the ad-hoc path it has no signature of its own
# and is covered by the outer app's signature overall, so verifying it directly
# reports "code object is not signed at all" — check whether it has a signature
# first.
if codesign -d "$APP/Contents/Resources/Mackit_Mackit.bundle" > /dev/null 2>&1; then
    codesign --verify --strict --verbose=2 "$APP/Contents/Resources/Mackit_Mackit.bundle" 2>&1 | sed 's/^/    /'
fi

SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
IS_DEVELOPER_ID=0
if echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
    IS_DEVELOPER_ID=1
fi
if [ "$IS_DEVELOPER_ID" = "1" ]; then
    # Notarization requires the hardened runtime; without it notarytool rejects the package outright.
    if ! echo "$SIGN_INFO" | grep -q "runtime"; then
        echo "Signing does not have the hardened runtime enabled; notarization would be rejected." >&2
        exit 1
    fi
    echo "    Developer ID Application + hardened runtime"
else
    echo "    Local signature (Developer ID Application identity not used)"
fi

# ---------- 4. Notarization credentials ----------
# Any one of the three forms; emptiness is checked with || chains, and the
# presence of any one means notarization will run.
NOTARY_MODE=""
if [ -n "${MACKIT_NOTARY_PROFILE:-}" ]; then
    NOTARY_MODE="profile"
elif [ -n "${MACKIT_API_KEY:-}" ] || [ -n "${MACKIT_API_KEY_ID:-}" ] || [ -n "${MACKIT_API_ISSUER:-}" ]; then
    NOTARY_MODE="apikey"
    MISSING=""
    [ -z "${MACKIT_API_KEY:-}" ] && MISSING="$MISSING MACKIT_API_KEY"
    [ -z "${MACKIT_API_KEY_ID:-}" ] && MISSING="$MISSING MACKIT_API_KEY_ID"
    [ -z "${MACKIT_API_ISSUER:-}" ] && MISSING="$MISSING MACKIT_API_ISSUER"
    if [ -n "$MISSING" ]; then
        echo "The App Store Connect API key requires all of these to be set: $MISSING" >&2
        exit 1
    fi
    # A ~ in an environment variable is not expanded automatically; handle it here.
    case "$MACKIT_API_KEY" in
        "~/"*) MACKIT_API_KEY="$HOME/${MACKIT_API_KEY#\~/}" ;;
    esac
    if [ ! -f "$MACKIT_API_KEY" ]; then
        echo "Key file does not exist: $MACKIT_API_KEY" >&2
        exit 1
    fi
    echo "==> Notarization credentials: App Store Connect API key ${MACKIT_API_KEY_ID}"
elif [ -n "${MACKIT_APPLE_ID:-}" ] || [ -n "${MACKIT_APP_PASSWORD:-}" ] || [ -n "${MACKIT_TEAM_ID:-}" ]; then
    NOTARY_MODE="appleid"
    MISSING=""
    [ -z "${MACKIT_APPLE_ID:-}" ] && MISSING="$MISSING MACKIT_APPLE_ID"
    [ -z "${MACKIT_APP_PASSWORD:-}" ] && MISSING="$MISSING MACKIT_APP_PASSWORD"
    [ -z "${MACKIT_TEAM_ID:-}" ] && MISSING="$MISSING MACKIT_TEAM_ID"
    if [ -n "$MISSING" ]; then
        echo "Apple ID notarization requires all of these to be set: $MISSING" >&2
        exit 1
    fi
    echo "==> Notarization credentials: Apple ID ${MACKIT_APPLE_ID}"
fi

# ---------- 5. Distribution form determination ----------
# A hard prerequisite for notarization is a Developer ID Application
# signature: packages signed with Apple Development / Apple Distribution
# identities are all rejected by notarytool, and Gatekeeper does not accept
# them either.
if [ -n "$NOTARY_MODE" ] && [ "$IS_DEVELOPER_ID" != "1" ]; then
    cat >&2 <<'MSG'
Error: Notarization requires signing with a Developer ID Application identity first.
Set MACKIT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" and retry;
if that certificate is missing from the keychain, create it on developer.apple.com and import it first.
MSG
    exit 1
fi
if [ -n "${MACKIT_SIGN_IDENTITY:-}" ] && [ "$IS_DEVELOPER_ID" != "1" ]; then
    echo "Warning: MACKIT_SIGN_IDENTITY is not a Developer ID Application identity," >&2
    echo "       so the distributed build would fail Gatekeeper (it still runs on this machine)." >&2
fi

# ---------- 6. Assemble the DMG ----------
echo "==> Generating DMG background image"
BACKGROUND="$BUILD_DIR/dmg-background.png"
swift "$ROOT/Scripts/make-dmg-background.swift" "$BACKGROUND"

echo "==> Assembling DMG contents"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
# ditto preserves extended attributes: signatures live in com.apple.cs.*, which cp -R does not guarantee to carry over.
ditto "$APP" "$STAGING/$VOLUME_NAME.app"
ln -s /Applications "$STAGING/Applications"
cp "$BACKGROUND" "$STAGING/.background/background.png"

# Verify the signature once more on the staging copy. A copy losing its
# signature is a silent failure, and discovering it at the notarization stage
# would be too late.
codesign --verify --strict --verbose=2 "$STAGING/$VOLUME_NAME.app" 2>&1 | sed 's/^/    /'

# First create a writable image (UDRW): UDZO is a read-only compressed format,
# so .DS_Store and the volume icon cannot be written after mounting; convert to
# the final UDZO after the layout is done.
# Keep using hdiutil here rather than the diskutil image suggested by the
# deprecation warning: the latter has no equivalent image format-conversion
# subcommand and only exists on newer macOS versions; hdiutil is only marked
# deprecated, its behavior is stable, and the WARNING in the output can be
# ignored.
TEMP_DMG="$BUILD_DIR/dmg-temp.dmg"
rm -f "$TEMP_DMG" "$DMG"
hdiutil create "$TEMP_DMG" -volname "$VOLUME_NAME" -fs HFS+ -srcfolder "$STAGING" -format UDRW -ov

# ---------- 7. Finder window layout ----------
# The layout is written to the .DS_Store inside the DMG, so it can only be done
# after mounting. Failure is purely cosmetic (the default icon view still
# works) and does not block the build.
if [ "${MACKIT_NO_LAYOUT:-0}" = "1" ]; then
    echo "==> Skipping Finder layout (MACKIT_NO_LAYOUT=1)"
else
    # An abnormal exit last time may have left a mount point behind, in which
    # case the new volume would become "Mackit 1" and the layout would find no
    # target.
    if [ -d "/Volumes/$VOLUME_NAME" ]; then
        echo "==> Detaching leftover mount /Volumes/$VOLUME_NAME"
        hdiutil detach "/Volumes/$VOLUME_NAME" > /dev/null 2>&1 \
            || hdiutil detach -force "/Volumes/$VOLUME_NAME" > /dev/null 2>&1 || true
    fi

    echo "==> Mounting and setting the window layout"
    ATTACH_OUTPUT="$(hdiutil attach "$TEMP_DMG" -nobrowse)"
    DEVICE="$(echo "$ATTACH_OUTPUT" | grep "/Volumes/$VOLUME_NAME" | awk '{print $1}')"
    MOUNT_POINT="/Volumes/$VOLUME_NAME"

    # Volume icon: the mounted volume shows Mackit's own icon in Finder.
    if command -v SetFile > /dev/null 2>&1; then
        cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
        SetFile -a C "$MOUNT_POINT/.VolumeIcon.icns" > /dev/null
    fi

    OSA_LOG="$BUILD_DIR/dmg-layout.log"
    OSA_RESULT="ok"
    osascript - "$VOLUME_NAME" > "$OSA_LOG" 2>&1 <<'APPLESCRIPT' &
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {120, 100, 840, 540}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 108
            -- Use a relative colon path for the background image: it is stored
            -- in .DS_Store as an alias of volume name + path, so it resolves
            -- the same way when mounted on another machine. An absolute path
            -- like /Volumes/xxx can also be set, but that kind of alias fails
            -- to resolve after hdiutil convert, and the background would be
            -- lost.
            set background picture of viewOptions to file ".background:background.png"
            set position of item "Mackit.app" of container window to {165, 150}
            set position of item "Applications" of container window to {555, 150}
            update without registering applications
            close
        end tell
    end tell
end run
APPLESCRIPT
    OSA_PID=$!
    if ! wait_bounded "$OSA_PID" "${MACKIT_LAYOUT_TIMEOUT:-60}"; then
        OSA_RESULT="timeout"
    elif [ "$WAIT_STATUS" != "0" ]; then
        OSA_RESULT="fail"
    fi

    if [ "$OSA_RESULT" = "ok" ]; then
        echo "    Layout done"
    elif [ "$OSA_RESULT" = "timeout" ]; then
        echo "    Warning: timed out waiting for Finder authorization, skipping layout (the DMG is still usable)" >&2
    else
        echo "    Warning: Finder layout failed, skipping layout (the DMG is still usable)" >&2
        echo "    First run requires allowing the Accessibility/Automation permission in the dialog. Log: $OSA_LOG" >&2
    fi

    hdiutil detach "$DEVICE" > /dev/null 2>&1 \
        || hdiutil detach -force "$DEVICE" > /dev/null 2>&1 || true
fi

# After the layout is done, compress to the delivery format. UDZO is read-only,
# so the conversion must come after the layout; with MACKIT_NO_LAYOUT=1 only the
# mount is skipped, and the conversion proceeds as usual.
mkdir -p "$DIST"
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG" -ov
rm -f "$TEMP_DMG"

# ---------- 8. Sign the DMG ----------
# Same timestamp-authority stall as build-app.sh: the request can hang ~15s
# and fail with the misleading "A timestamp was expected but was not found",
# so retry instead of letting one dropped request abort the release.
sign_codesign() {
    local attempt
    for attempt in 1 2 3 4; do
        codesign "$@" && return 0
        echo "  codesign attempt $attempt failed; retrying" >&2
        sleep 3
    done
    return 1
}
if [ -n "${MACKIT_SIGN_IDENTITY:-}" ]; then
    echo "==> Signing DMG"
    sign_codesign --force --sign "$MACKIT_SIGN_IDENTITY" --timestamp "$DMG"
    codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
fi

# ---------- 9. Notarize and staple ----------
if [ -n "$NOTARY_MODE" ]; then
    echo "==> Submitting for notarization (usually takes a few minutes)"
    NOTARY_LOG="$BUILD_DIR/notarytool.log"
    NOTARY_OK=0
    case "$NOTARY_MODE" in
        profile)
            xcrun notarytool submit "$DMG" \
                --keychain-profile "$MACKIT_NOTARY_PROFILE" --wait \
                > "$NOTARY_LOG" 2>&1 && NOTARY_OK=1
            ;;
        apikey)
            xcrun notarytool submit "$DMG" \
                --key "$MACKIT_API_KEY" --key-id "$MACKIT_API_KEY_ID" --issuer "$MACKIT_API_ISSUER" \
                --wait > "$NOTARY_LOG" 2>&1 && NOTARY_OK=1
            ;;
        appleid)
            xcrun notarytool submit "$DMG" \
                --apple-id "$MACKIT_APPLE_ID" --password "$MACKIT_APP_PASSWORD" --team-id "$MACKIT_TEAM_ID" \
                --wait > "$NOTARY_LOG" 2>&1 && NOTARY_OK=1
            ;;
    esac
    # notarytool's exit code is only 0 when Accepted; the grep is a second safety net.
    if [ "$NOTARY_OK" != "1" ] || ! grep -q "Accepted" "$NOTARY_LOG"; then
        echo "Notarization failed, notarytool log:" >&2
        tail -30 "$NOTARY_LOG" >&2
        exit 1
    fi
    echo "    Notarization passed"

    echo "==> Stapling the notarization ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    # Gatekeeper final check: if this step fails, warnings still pop up on users' machines.
    echo "==> Gatekeeper assessment"
    if spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /'; then
        :
    else
        echo "Gatekeeper assessment failed (see above); do not distribute this package." >&2
        exit 1
    fi
fi

# ---------- 10. Checksum and delivery notes ----------
echo "==> Generating checksum"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo
echo "Done: ${DMG} (${SIZE})"
echo "Checksum: ${DMG}.sha256"

if [ -n "$NOTARY_MODE" ]; then
    echo "Status: Developer ID Application signed + notarized and stapled; users can open it directly after downloading."
elif [ -n "${MACKIT_SIGN_IDENTITY:-}" ]; then
    cat <<'MSG'

Status: signed, but not notarized. Users will still see a "developer cannot be verified" warning on first open.
Re-run this script after filling in the notarization credentials (API key / Apple ID / keychain profile, any one of them).
MSG
else
    cat <<'MSG'

Status: local ad-hoc signature, runs on this machine only; do not distribute directly.
If you must let users try it, tell them:
  1. In Finder, right-click Mackit.app, choose "Open", then click "Open" again in the dialog; or
  2. Remove the quarantine attribute: xattr -dr com.apple.quarantine /Applications/Mackit.app
For formal distribution, set MACKIT_SIGN_IDENTITY and the notarization credentials, then re-run this script.
MSG
fi
