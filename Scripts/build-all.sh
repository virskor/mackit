#!/bin/bash
# One-shot release pipeline: build → sign → notarize → Sparkle update → GitHub Release
# Usage: Scripts/build-all.sh [options]
#
# Drives the full release flow documented in docs/RELEASE.md end to end:
#   1. Preflight — signing identity, notarization credentials, Sparkle keys,
#      git tag, clean tree, gh CLI. Everything that would otherwise fail slowly
#      (a missing certificate surfaces only after notarization has run for
#      minutes) is checked up front.
#   2. Scripts/build-dmg.sh    — universal build, Developer ID signature,
#      notarization, ticket stapling, Gatekeeper assessment.
#   3. Scripts/build-update.sh — Sparkle update archive + appcast.
#   4. gh release create       — uploads the four release assets.
#
# Options:
#   --tag <version>   Create and push annotated tag v<version> at HEAD before
#                     building (fails if the tag already exists). Without it
#                     the most recent tag reachable from HEAD is used and must
#                     already exist.
#   --skip-update     Skip the Sparkle step. Implies --skip-release: a release
#                     published without its appcast.xml makes the
#                     releases/latest feed 404 for every installed copy.
#   --skip-release    Stop after the artifacts are built and verified.
#   --draft           Create the GitHub release as a draft.
#   --allow-dirty     Proceed with uncommitted changes. The binary is built
#                     from the working tree, so it would not match the tag.
#   --no-notes        Publish without a release-notes file.
#   --env-file <path> Source a file of credentials before preflight (default:
#                     .env.release at the repo root, when present). Assignments
#                     are exported automatically; .gitignore blocks .env*.
#   --dry-run         Preflight and print the plan, build nothing.
#   -h, --help        Show this help.
#
# Credentials come from the environment (details in docs/RELEASE.md):
#   MACKIT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   MACKIT_API_KEY / MACKIT_API_KEY_ID / MACKIT_API_ISSUER  — notarytool, one of
#     the three credential forms: keychain profile / API key / Apple ID
#   MACKIT_UPDATE_PUBLIC_KEY  EdDSA public key printed by generate_keys
#   MACKIT_ED_KEY_FILE        EdDSA private key file (login keychain when unset)
#
# Derived from the origin remote unless already set:
#   MACKIT_UPDATE_FEED_URL      .../releases/latest/download/appcast.xml
#   MACKIT_DOWNLOAD_URL_PREFIX  .../releases/download/v<version>/
#   MACKIT_NOTES_FILE           docs/release-notes/v<version>.md
# Example
# Scripts/build-all.sh --tag 1.1.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/Mackit.app"
DIST="$ROOT/dist"

die() {
    echo "error: $*" >&2
    exit 1
}

# ---------- Options ----------
TAG_ARG=""
ENV_FILE=""
SKIP_UPDATE=0
SKIP_RELEASE=0
DRAFT=0
ALLOW_DIRTY=0
NO_NOTES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            [ $# -ge 2 ] || die "--tag requires a version (e.g. --tag 1.2.0)"
            TAG_ARG="$2"
            shift 2
            ;;
        --env-file)
            [ $# -ge 2 ] || die "--env-file requires a path"
            ENV_FILE="$2"
            shift 2
            ;;
        --skip-update)
            SKIP_UPDATE=1
            shift
            ;;
        --skip-release)
            SKIP_RELEASE=1
            shift
            ;;
        --draft)
            DRAFT=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --no-notes)
            NO_NOTES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            # Print the leading comment block; awk keeps it correct when the
            # header grows, and ERE '?' works here unlike BSD sed's '\?'.
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            die "unknown option: $1 (see Scripts/build-all.sh --help)"
            ;;
    esac
done

if [ "$SKIP_UPDATE" = "1" ] && [ "$SKIP_RELEASE" = "0" ]; then
    echo "note: --skip-update implies --skip-release" >&2
    echo "      (publishing without appcast.xml breaks the feed for every" >&2
    echo "      installed copy; publish later with 'gh release create' or" >&2
    echo "      'gh release upload' once build-update.sh has run)" >&2
    SKIP_RELEASE=1
fi

# ---------- Credentials file ----------
# set -a exports every assignment made while sourcing, so a plain
# KEY=value file works without requiring 'export' on each line.
if [ -z "$ENV_FILE" ] && [ -f "$ROOT/.env.release" ]; then
    ENV_FILE="$ROOT/.env.release"
fi
if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
    echo "==> Loading credentials from $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

# ---------- Resolve the GitHub slug ----------
# Feed and archive URLs are per-repository conventions (docs/RELEASE.md);
# deriving them from origin keeps them correct after a fork or rename.
SLUG=""
if REMOTE_URL="$(git remote get-url origin 2>/dev/null)"; then
    SLUG="${REMOTE_URL%.git}"
    case "$SLUG" in
        git@github.com:*)    SLUG="${SLUG#git@github.com:}" ;;
        https://github.com/*) SLUG="${SLUG#https://github.com/}" ;;
        http://github.com/*)  SLUG="${SLUG#http://github.com/}" ;;
        *) SLUG="" ;;
    esac
    case "$SLUG" in
        */*/*|*" "*|"") SLUG="" ;;
    esac
fi
[ -n "$SLUG" ] || die "cannot derive owner/repo from 'git remote get-url origin'; set MACKIT_UPDATE_FEED_URL and MACKIT_DOWNLOAD_URL_PREFIX manually"

# ---------- Resolve the version and tag ----------
# The git tag is the single source of truth for the version (same rule as
# build-app.sh), so the release tag, the DMG name and the appcast entry all
# agree by construction.
if [ -n "$TAG_ARG" ]; then
    VERSION="${TAG_ARG#v}"
    case "$VERSION" in
        ""|*" "*|*/*) die "invalid version: '$TAG_ARG'" ;;
    esac
    TAG="v$VERSION"
    if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
        die "tag $TAG already exists; drop --tag to build it, or pick a new version"
    fi
    CREATE_TAG=1
else
    CREATE_TAG=0
    if [ -n "${MACKIT_VERSION:-}" ]; then
        VERSION="$MACKIT_VERSION"
    elif DESCRIBED="$(git describe --tags --abbrev=0 2>/dev/null)"; then
        VERSION="${DESCRIBED#v}"
    else
        die "no tag reachable from HEAD; create one with --tag <version>"
    fi
    TAG="v$VERSION"
    git rev-parse -q --verify "refs/tags/$TAG" > /dev/null \
        || die "tag $TAG does not exist; create it with 'git tag -a $TAG -m \"Mackit $VERSION\"' and push, or pass --tag $VERSION"
fi

# ---------- Derived defaults ----------
export MACKIT_UPDATE_FEED_URL="${MACKIT_UPDATE_FEED_URL:-https://github.com/$SLUG/releases/latest/download/appcast.xml}"
export MACKIT_DOWNLOAD_URL_PREFIX="${MACKIT_DOWNLOAD_URL_PREFIX:-https://github.com/$SLUG/releases/download/$TAG/}"
if [ "$NO_NOTES" = "0" ] && [ -z "${MACKIT_NOTES_FILE:-}" ]; then
    MACKIT_NOTES_FILE="$ROOT/docs/release-notes/$TAG.md"
fi
NOTES_FILE="${MACKIT_NOTES_FILE:-}"
# build-update.sh reads MACKIT_NOTES_FILE from the environment to embed the
# notes in the appcast item; without the export the in-app update window
# shows a version number with no release notes.
export MACKIT_NOTES_FILE

# ---------- Preflight ----------
echo "==> Preflight"

# Developer ID Application is a hard prerequisite: notarytool rejects every
# other identity, and Gatekeeper will not accept the result either.
[ -n "${MACKIT_SIGN_IDENTITY:-}" ] \
    || die "MACKIT_SIGN_IDENTITY is not set (e.g. \"Developer ID Application: Name (TEAMID)\")"
# Checking the keychain here turns a minutes-late failure into an immediate one.
security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$MACKIT_SIGN_IDENTITY\"" \
    || die "identity not in keychain: $MACKIT_SIGN_IDENTITY (create and import it at developer.apple.com)"

# Notarization credentials: exactly one of the three forms, all of its parts
# present (same rules as build-dmg.sh, checked here before the long build).
NOTARY_MODE=""
if [ -n "${MACKIT_NOTARY_PROFILE:-}" ]; then
    NOTARY_MODE="keychain profile '$MACKIT_NOTARY_PROFILE'"
elif [ -n "${MACKIT_API_KEY:-}" ] || [ -n "${MACKIT_API_KEY_ID:-}" ] || [ -n "${MACKIT_API_ISSUER:-}" ]; then
    NOTARY_MODE="App Store Connect API key"
    [ -n "${MACKIT_API_KEY:-}" ] && [ -n "${MACKIT_API_KEY_ID:-}" ] && [ -n "${MACKIT_API_ISSUER:-}" ] \
        || die "API key notarization needs MACKIT_API_KEY, MACKIT_API_KEY_ID and MACKIT_API_ISSUER together"
    case "$MACKIT_API_KEY" in
        "~/"*) MACKIT_API_KEY="$HOME/${MACKIT_API_KEY#\~/}" ;;
    esac
    [ -f "$MACKIT_API_KEY" ] || die "API key file not found: $MACKIT_API_KEY"
    export MACKIT_API_KEY
elif [ -n "${MACKIT_APPLE_ID:-}" ] || [ -n "${MACKIT_APP_PASSWORD:-}" ] || [ -n "${MACKIT_TEAM_ID:-}" ]; then
    NOTARY_MODE="Apple ID ${MACKIT_APPLE_ID:-?}"
    [ -n "${MACKIT_APPLE_ID:-}" ] && [ -n "${MACKIT_APP_PASSWORD:-}" ] && [ -n "${MACKIT_TEAM_ID:-}" ] \
        || die "Apple ID notarization needs MACKIT_APPLE_ID, MACKIT_APP_PASSWORD and MACKIT_TEAM_ID together"
else
    die "no notarization credentials: set MACKIT_NOTARY_PROFILE, or the API key triple, or the Apple ID triple (see docs/RELEASE.md)"
fi

# Sparkle keys: the public key ships in Info.plist, the private key signs the
# archive. A feed without the public key makes Sparkle refuse every update.
[ -n "${MACKIT_UPDATE_PUBLIC_KEY:-}" ] \
    || die "MACKIT_UPDATE_PUBLIC_KEY is not set (generate a pair once with .build/sparkle-tools/bin/generate_keys)"
if [ -n "${MACKIT_ED_KEY_FILE:-}" ]; then
    [ -f "$MACKIT_ED_KEY_FILE" ] || die "EdDSA key file not found: $MACKIT_ED_KEY_FILE"
fi

# Release notes: the same file feeds the appcast (embedded) and the GitHub
# release, following the docs/release-notes/ convention.
if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "release notes not found: $NOTES_FILE (pass --no-notes to publish without them)"
fi

# The binary is built from the working tree, so uncommitted changes — including
# untracked new sources, which swift build compiles in — would silently ship
# code the tag does not contain. Ignored files (dist/, .build/) are excluded.
if [ "$ALLOW_DIRTY" = "0" ] && [ -n "$(git status --porcelain)" ]; then
    git status --short | sed 's/^/    /' >&2
    die "working tree has uncommitted changes (commit them, or pass --allow-dirty)"
fi

if [ "$CREATE_TAG" = "0" ] && [ "$(git rev-parse HEAD)" != "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")" ]; then
    echo "warning: HEAD is ahead of $TAG — the build includes unreleased commits" >&2
fi

if [ "$SKIP_RELEASE" = "0" ]; then
    command -v gh > /dev/null 2>&1 \
        || die "gh CLI not found (install: brew install gh, or pass --skip-release)"
    gh auth status > /dev/null 2>&1 \
        || die "gh is not authenticated (run 'gh auth login', or pass --skip-release)"
    if gh release view "$TAG" > /dev/null 2>&1; then
        die "release $TAG already exists on GitHub (delete it first, or build a new version)"
    fi
fi

# ---------- Plan ----------
echo
echo "Release plan"
echo "  version:      $VERSION (tag $TAG)"
[ "$CREATE_TAG" = "1" ] && echo "  tag:          created and pushed before the build"
echo "  repository:   https://github.com/$SLUG"
echo "  signing:      $MACKIT_SIGN_IDENTITY"
echo "  notarizing:   $NOTARY_MODE"
echo "  feed URL:     $MACKIT_UPDATE_FEED_URL"
echo "  archive base: $MACKIT_DOWNLOAD_URL_PREFIX"
[ -n "$NOTES_FILE" ] && echo "  notes:        $NOTES_FILE"
[ "$SKIP_UPDATE" = "1" ] && echo "  updates:      skipped (no Sparkle archive / appcast)"
if [ "$SKIP_RELEASE" = "1" ]; then
    echo "  publish:      skipped (artifacts only)"
elif [ "$DRAFT" = "1" ]; then
    echo "  publish:      gh release create --draft"
else
    echo "  publish:      gh release create (public, immediately visible)"
fi
echo "  arches:       ${MACKIT_ARCHES:-arm64 x86_64 (default)}"
echo

if [ "$DRY_RUN" = "1" ]; then
    echo "dry run: preflight passed, nothing built"
    exit 0
fi

# ---------- 1. Build, sign, notarize ----------
# The tag is created here rather than in preflight: a failed preflight must
# not leave a pushed tag behind, and --dry-run exits before this point.
if [ "$CREATE_TAG" = "1" ]; then
    echo "==> Creating and pushing tag $TAG"
    git tag -a "$TAG" -m "Mackit $VERSION"
    git push origin "$TAG"
fi

T0=$SECONDS
"$ROOT/Scripts/build-dmg.sh" release
echo "==> DMG ready ($((SECONDS - T0))s)"

# build-app.sh resolves the version with the same tag rule, but read it back
# from the built bundle so a stale MACKIT_VERSION cannot desynchronize the
# artifact names from the release tag.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$BUILT_VERSION" = "$VERSION" ] \
    || die "built version '$BUILT_VERSION' does not match tag version '$VERSION'"

# ---------- 2. Sparkle update archive + appcast ----------
if [ "$SKIP_UPDATE" = "0" ]; then
    T0=$SECONDS
    "$ROOT/Scripts/build-update.sh"
    echo "==> Update archive and appcast ready ($((SECONDS - T0))s)"
fi

# ---------- 3. Verify the assets ----------
echo "==> Verifying release assets"
DMG="$DIST/Mackit-$VERSION.dmg"
ASSETS=("$DMG" "$DMG.sha256")
if [ "$SKIP_UPDATE" = "0" ]; then
    ASSETS+=("$DIST/updates/Mackit-$VERSION.tar.bz2" "$DIST/updates/appcast.xml")
    # Delta archives referenced by this release's appcast entry are release
    # assets too: generate_appcast emits them whenever a previous archive is
    # still around, and an enclosure without its file 404s for every client
    # that picks the delta.
    while IFS= read -r delta; do
        [ -n "$delta" ] && ASSETS+=("$DIST/updates/$delta")
    done < <(grep -oE "releases/download/$TAG/[^\"]+\.delta" "$DIST/updates/appcast.xml" | sed "s|releases/download/$TAG/||" | sort -u)
fi
for asset in "${ASSETS[@]}"; do
    [ -s "$asset" ] || die "missing or empty asset: $asset"
    echo "    $(du -h "$asset" | awk '{print $1}')  $asset"
done
if [ "$SKIP_UPDATE" = "0" ]; then
    # The appcast must advertise exactly the archive being uploaded; a mismatch
    # means the feed would point at a stale or missing enclosure.
    grep -q "Mackit-$VERSION.tar.bz2" "$DIST/updates/appcast.xml" \
        || die "appcast.xml does not reference Mackit-$VERSION.tar.bz2"
    echo "    appcast references this version"
fi

if [ "$SKIP_RELEASE" = "1" ]; then
    echo
    echo "done: artifacts built and verified (publish skipped)"
    echo "  $DMG"
    [ "$SKIP_UPDATE" = "0" ] && echo "  $DIST/updates/appcast.xml"
    exit 0
fi

# ---------- 4. Publish ----------
T0=$SECONDS
GH_ARGS=("$TAG" "${ASSETS[@]}" --title "Mackit $VERSION")
if [ "$DRAFT" = "1" ]; then
    GH_ARGS+=(--draft)
fi
if [ -n "$NOTES_FILE" ]; then
    GH_ARGS+=(--notes-file "$NOTES_FILE")
else
    GH_ARGS+=(--notes "Mackit $VERSION")
fi
gh release create "${GH_ARGS[@]}"
echo "==> Release published ($((SECONDS - T0))s)"

RELEASE_URL="$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "https://github.com/$SLUG/releases/tag/$TAG")"
echo
echo "done: $RELEASE_URL"
echo "  feed: $MACKIT_UPDATE_FEED_URL"
echo "  installed copies pick this up on the next update check (24h by default;"
echo "  'Check for Updates…' in the app menu forces it immediately)."
echo "  asset propagation on the CDN can lag a minute — verify with:"
echo "    curl -sI \"$MACKIT_UPDATE_FEED_URL\""
