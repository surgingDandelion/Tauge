#!/bin/bash
# Cut a Tauge release from a tag and wait for the GitHub Release to go live.
#
#   ./scripts/release.sh patch
#   ./scripts/release.sh 1.2.0 --notes-file /tmp/notes.md
#   ./scripts/release.sh --current
#
# The script is intentionally conservative: it refuses to run on a dirty tree,
# on a branch other than main, when main is behind origin, or when the tag
# already exists. It updates Info.plist and CHANGELOG.md, commits, pushes main,
# pushes an annotated tag, and polls the public release page until the workflow
# has published the DMG, ZIP, and SHA256SUMS.txt.
#
# Options:
#   --current             Release the version already in Info.plist (retry a tag)
#   --notes TEXT          Markdown body for a new CHANGELOG entry
#   --notes-file FILE     Read the markdown body from FILE
#   --yes, -y             Do not ask for confirmation
#   --dry-run             Print the plan and exit without changing anything
#   --skip-checks         Skip the local localisation and self-check suite
#   --no-wait             Push the tag and exit instead of waiting for GitHub
#   --repo OWNER/REPO     Override the repository inferred from origin
#
# Environment:
#   GITHUB_TOKEN / GH_TOKEN   Optional; raises the API rate limit and enables
#                             digest verification on private repositories.
#   RELEASE_POLL_SECONDS      Poll interval (default 60)
#   RELEASE_TIMEOUT_SECONDS   Maximum wait (default 3600)
#
# Releasing without a Developer ID identity is allowed, but the published app
# is ad-hoc signed. Configure the secrets in docs/SIGNING.md for a notarised
# build that installs without a Gatekeeper prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
CHANGELOG="CHANGELOG.md"
MAIN_BRANCH="main"
APP_NAME="Tauge"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
POLL_SECONDS="${RELEASE_POLL_SECONDS:-60}"
TIMEOUT_SECONDS="${RELEASE_TIMEOUT_SECONDS:-3600}"

VERSION_ARG=""
NOTES=""
NOTES_FILE=""
ASSUME_YES=0
DRY_RUN=0
SKIP_CHECKS=0
WAIT=1
REPO_OVERRIDE=""

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --current)
            VERSION_ARG="--current"
            shift
            ;;
        --notes)
            [ $# -ge 2 ] || die "--notes needs a value"
            NOTES="$2"
            shift 2
            ;;
        --notes-file)
            [ $# -ge 2 ] || die "--notes-file needs a path"
            NOTES_FILE="$2"
            shift 2
            ;;
        --yes|-y)
            ASSUME_YES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-checks)
            SKIP_CHECKS=1
            shift
            ;;
        --no-wait)
            WAIT=0
            shift
            ;;
        --repo)
            [ $# -ge 2 ] || die "--repo needs OWNER/REPO"
            REPO_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            [ -z "$VERSION_ARG" ] || die "only one version or bump argument is allowed"
            VERSION_ARG="$1"
            shift
            ;;
    esac
done

[ -n "$VERSION_ARG" ] || die "give a version (1.2.0), a bump (patch|minor|major), or --current"

# Refuse to release from an ambiguous state. This also keeps a concurrent
# worktree from being swept into the release commit.
[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash changes first"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$MAIN_BRANCH" ] || die "release from the $MAIN_BRANCH branch"

REMOTE="$(git remote get-url origin 2>/dev/null || true)"
[ -n "$REMOTE" ] || die "origin remote is not configured"
if [ -n "$REPO_OVERRIDE" ]; then
    REPO="$REPO_OVERRIDE"
else
    case "$REMOTE" in
        git@github.com:*) REPO="${REMOTE#git@github.com:}" ;;
        https://github.com/*) REPO="${REMOTE#https://github.com/}" ;;
        ssh://git@github.com/*) REPO="${REMOTE#ssh://git@github.com/}" ;;
        *) die "origin is not a GitHub remote: $REMOTE" ;;
    esac
    REPO="${REPO%.git}"
fi
[[ "$REPO" == */* ]] || die "repository must be OWNER/REPO, got: $REPO"

note "fetching origin/$MAIN_BRANCH and tags"
git fetch --quiet --tags origin "$MAIN_BRANCH"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$MAIN_BRANCH")" ] ||
    die "HEAD is not origin/$MAIN_BRANCH; push or pull first"

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Info.plist has an unexpected version: $CURRENT_VERSION"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || CURRENT_BUILD=0

LATEST_TAG="$(git tag --sort=-v:refname --list 'v[0-9]*' | sed -n '1p')"
LATEST_VERSION="${LATEST_TAG#v}"
[ -n "$LATEST_VERSION" ] || LATEST_VERSION="0.0.0"

MODE="explicit"
case "$VERSION_ARG" in
    --current)
        TARGET_VERSION="$CURRENT_VERSION"
        MODE="current"
        ;;
    patch|minor|major)
        IFS=. read -r CUR_MAJOR CUR_MINOR CUR_PATCH <<< "$CURRENT_VERSION"
        case "$VERSION_ARG" in
            patch) TARGET_VERSION="$CUR_MAJOR.$CUR_MINOR.$((CUR_PATCH + 1))" ;;
            minor) TARGET_VERSION="$CUR_MAJOR.$((CUR_MINOR + 1)).0" ;;
            major) TARGET_VERSION="$((CUR_MAJOR + 1)).0.0" ;;
        esac
        MODE="bump"
        ;;
    *)
        TARGET_VERSION="${VERSION_ARG#v}"
        ;;
esac

[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "version must look like 1.2.3 (got: $TARGET_VERSION)"

version_gt() {
    python3 - "$1" "$2" <<'PY'
import sys
a = tuple(int(part) for part in sys.argv[1].split("."))
b = tuple(int(part) for part in sys.argv[2].split("."))
sys.exit(0 if a > b else 1)
PY
}

if [ "$MODE" = "current" ]; then
    [ "$TARGET_VERSION" = "$CURRENT_VERSION" ] || die "--current requires Info.plist to already be at $TARGET_VERSION"
else
    version_gt "$TARGET_VERSION" "$CURRENT_VERSION" ||
        die "$TARGET_VERSION must be greater than the current Info.plist version $CURRENT_VERSION"
fi
version_gt "$TARGET_VERSION" "$LATEST_VERSION" ||
    die "$TARGET_VERSION must be greater than the latest tag v$LATEST_VERSION"

TAG="v$TARGET_VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists locally"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists on origin"
fi

if [ "$TARGET_VERSION" = "$CURRENT_VERSION" ]; then
    TARGET_BUILD="$CURRENT_BUILD"
else
    TARGET_BUILD=$((CURRENT_BUILD + 1))
fi

if [ -n "$NOTES" ] && [ -n "$NOTES_FILE" ]; then
    die "use either --notes or --notes-file, not both"
fi
if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "notes file not found: $NOTES_FILE"
    NOTES="$(cat "$NOTES_FILE")"
fi
[ -n "$NOTES" ] || NOTES=""

HAS_CHANGELOG_SECTION=0
if grep -q "^## \[$TARGET_VERSION\]" "$CHANGELOG"; then
    HAS_CHANGELOG_SECTION=1
fi
if [ "$HAS_CHANGELOG_SECTION" = 1 ] && [ -n "$NOTES" ]; then
    die "CHANGELOG.md already has a $TARGET_VERSION section; edit it instead of passing --notes"
fi
if [ "$HAS_CHANGELOG_SECTION" = 0 ] && [ -z "$NOTES" ]; then
    die "no CHANGELOG.md section for $TARGET_VERSION; add one or pass --notes/--notes-file"
fi

echo
echo "Release plan"
echo "  repository: $REPO"
echo "  version:    $CURRENT_VERSION -> $TARGET_VERSION"
echo "  build:      $CURRENT_BUILD -> $TARGET_BUILD"
echo "  tag:        $TAG"
echo "  changelog:  $([ "$HAS_CHANGELOG_SECTION" = 1 ] && echo "existing section" || echo "new section from notes")"
echo "  checks:     $([ "$SKIP_CHECKS" = 1 ] && echo "skipped" || echo "localisation + ShellXChecks")"
echo "  wait:       $([ "$WAIT" = 1 ] && echo "yes, up to ${TIMEOUT_SECONDS}s" || echo "no")"
echo

if [ "$DRY_RUN" = 1 ]; then
    note "dry run; no files changed"
    exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
    [ -t 0 ] || die "non-interactive shell; pass --yes to publish"
    printf "Publish %s? [y/N] " "$TAG"
    read -r ANSWER
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

if [ "$SKIP_CHECKS" = 1 ]; then
    note "skipping local checks (CI still runs them)"
else
    note "checking localisation coverage"
    python3 scripts/check-localization.py
    note "running self-checks"
    swift run --disable-sandbox ShellXChecks
fi

if [ "$HAS_CHANGELOG_SECTION" = 0 ]; then
    note "adding CHANGELOG.md section for $TARGET_VERSION"
    NOTES_TMP="$(mktemp -t tauge-release-notes)"
    printf '%s\n' "$NOTES" > "$NOTES_TMP"
    python3 - "$TARGET_VERSION" "$(date +%F)" "$NOTES_TMP" <<'PY'
import pathlib
import sys

version, day, notes_path = sys.argv[1], sys.argv[2], sys.argv[3]
notes = pathlib.Path(notes_path).read_text(encoding="utf-8").strip()
if not notes:
    sys.exit("release notes are empty")

path = pathlib.Path("CHANGELOG.md")
text = path.read_text(encoding="utf-8")
marker = "## [Unreleased]"
start = text.find(marker)
if start < 0:
    sys.exit("CHANGELOG.md has no ## [Unreleased] section")
next_heading = text.find("\n## [", start + len(marker))
block = f"\n## [{version}] — {day}\n\n{notes}\n"
if next_heading < 0:
    text = text.rstrip() + "\n" + block
else:
    text = text[:next_heading] + block + text[next_heading:]
path.write_text(text, encoding="utf-8")
PY
    rm -f "$NOTES_TMP"
fi

note "updating $PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TARGET_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TARGET_BUILD" "$PLIST"

if git diff --quiet -- "$PLIST" "$CHANGELOG"; then
    note "version files already at $TARGET_VERSION; tagging the current commit"
else
    git add "$PLIST" "$CHANGELOG"
    git commit -m "chore(release): $TAG"
fi

note "creating annotated tag $TAG"
git tag -a "$TAG" -m "$APP_NAME $TARGET_VERSION"

note "pushing $MAIN_BRANCH"
git push origin "$MAIN_BRANCH"
note "pushing $TAG"
git push origin "$TAG"

RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
ACTIONS_URL="https://github.com/$REPO/actions/workflows/release.yml"

echo
note "tag pushed; GitHub Actions is building the release"
echo "    workflow: $ACTIONS_URL"
echo "    release:  $RELEASE_URL"
echo

if [ "$WAIT" = 0 ]; then
    note "--no-wait; stopping here"
    exit 0
fi

TMP_PAGE="$(mktemp -t tauge-release-page)"
TMP_JSON="$(mktemp -t tauge-release-json)"
trap 'rm -f "$TMP_PAGE" "$TMP_JSON"' EXIT

START_TIME="$(date +%s)"
DEADLINE=$((START_TIME + TIMEOUT_SECONDS))
while :; do
    NOW="$(date +%s)"
    if [ "$NOW" -ge "$DEADLINE" ]; then
        echo
        echo "error: timed out after ${TIMEOUT_SECONDS}s waiting for $RELEASE_URL" >&2
        echo "       inspect the workflow: $ACTIONS_URL" >&2
        exit 1
    fi

    CODE="$(curl -sS -L -A 'Tauge-release-script' --max-time 30 \
        -o "$TMP_PAGE" -w '%{http_code}' "$RELEASE_URL" 2>/dev/null || true)"
    if [ "$CODE" = "200" ] &&
       grep -q "Tauge-$TARGET_VERSION.dmg" "$TMP_PAGE" &&
       grep -q "Tauge-$TARGET_VERSION.zip" "$TMP_PAGE"; then
        break
    fi

    ELAPSED=$((NOW - START_TIME))
    note "still building (elapsed ${ELAPSED}s); next check in ${POLL_SECONDS}s"
    sleep "$POLL_SECONDS"
done

echo
note "release is live: $RELEASE_URL"

# The release page is the source of truth. The API check below adds the asset
# sizes and verifies SHA256SUMS.txt against GitHub's recorded digests; a rate
# limit or an offline API must not turn a successful release into a failure.
API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
CURL_ARGS=(-sS -L -A 'Tauge-release-script' --max-time 30)
if [ -n "$TOKEN" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer $TOKEN")
fi
API_STATUS=0
if ! curl "${CURL_ARGS[@]}" "$API_URL" -o "$TMP_JSON" 2>/dev/null; then
    API_STATUS=2
elif python3 - "$TMP_JSON" "$TARGET_VERSION" <<'PY'
import json
import sys
import urllib.request

path, version = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
if data.get("message"):
    print(f"    note: GitHub API unavailable: {data['message']}")
    sys.exit(2)

if data.get("draft") or data.get("prerelease"):
    sys.exit("release is draft or prerelease")

assets = {asset["name"]: asset for asset in data.get("assets", [])}
required = [f"Tauge-{version}.dmg", f"Tauge-{version}.zip", "SHA256SUMS.txt"]
missing = [name for name in required if name not in assets]
if missing:
    sys.exit("release is missing assets: " + ", ".join(missing))

sums_asset = assets["SHA256SUMS.txt"]
request = urllib.request.Request(
    sums_asset["browser_download_url"],
    headers={"User-Agent": "Tauge-release-script"},
)
with urllib.request.urlopen(request, timeout=30) as response:
    sums_text = response.read().decode("utf-8")

checksums = {}
for line in sums_text.splitlines():
    fields = line.split()
    if len(fields) != 2:
        sys.exit(f"malformed SHA256SUMS.txt line: {line!r}")
    checksums[fields[1]] = fields[0]

for name in required:
    asset = assets[name]
    if not asset.get("browser_download_url", "").startswith("https://"):
        sys.exit(f"asset URL is not HTTPS: {name}")
    if asset.get("size", 0) <= 0:
        sys.exit(f"asset is empty: {name}")
    digest = asset.get("digest") or ""
    if name != "SHA256SUMS.txt":
        expected = checksums.get(name)
        if not expected:
            sys.exit(f"SHA256SUMS.txt does not list {name}")
        if digest and digest != f"sha256:{expected}":
            sys.exit(f"checksum mismatch for {name}")
    print(f"    {name}: {asset['size']} bytes" + (f" sha256:{digest.split(':', 1)[1]}" if digest else ""))

print("    SHA256SUMS.txt matches the published assets")
PY
then
    API_STATUS=0
else
    API_STATUS=$?
fi

if [ "$API_STATUS" = 2 ]; then
    note "release page is live; skipped API digest verification"
elif [ "$API_STATUS" -ne 0 ]; then
    echo "warning: release is live but asset verification failed" >&2
    exit 1
fi

echo
note "done: $RELEASE_URL"
echo "    updater: /Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME --check-updates"
