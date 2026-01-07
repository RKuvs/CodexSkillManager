#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIP=${1:?
"Usage: $0 MyApp-<ver>.zip"}
FEED_URL=${2:-"https://raw.githubusercontent.com/Dimillian/CodexSkillManager/main/appcast.xml"}
PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}
if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to your ed25519 private key (Sparkle)." >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "Zip not found: $ZIP" >&2
  exit 1
fi

ZIP_DIR=$(cd "$(dirname "$ZIP")" && pwd)
ZIP_NAME=$(basename "$ZIP")
ZIP_BASE="${ZIP_NAME%.zip}"
VERSION=${SPARKLE_RELEASE_VERSION:-}
if [[ -z "$VERSION" ]]; then
  if [[ "$ZIP_NAME" =~ ^[^-]+-([0-9]+(\.[0-9]+){1,2}([-.][^.]*)?)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "Could not infer version from $ZIP_NAME; set SPARKLE_RELEASE_VERSION." >&2
    exit 1
  fi
fi

NOTES_HTML="${ZIP_DIR}/${ZIP_BASE}.html"
KEEP_NOTES=${KEEP_SPARKLE_NOTES:-0}
if [[ -x "$ROOT/Scripts/changelog-to-html.sh" ]]; then
  "$ROOT/Scripts/changelog-to-html.sh" "$VERSION" >"$NOTES_HTML"
else
  cat >"$NOTES_HTML" <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>${ZIP_BASE}</title>
<body>
<h2>${ZIP_BASE}</h2>
<p>Release notes not provided.</p>
</body>
</html>
HTML
fi
cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ "$KEEP_NOTES" != "1" ]]; then
    rm -f "$NOTES_HTML"
  fi
}
trap cleanup EXIT

DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-"https://github.com/Dimillian/CodexSkillManager/releases/download/v${VERSION}/"}

GEN_APPCAST=$(command -v generate_appcast || true)
TEMP_DIR=""
cleanup_tools() {
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup_tools EXIT

if [[ -z "$GEN_APPCAST" ]]; then
  TEMP_DIR=$(mktemp -d /tmp/sparkle-appcast.XXXXXX)
  curl -sL -o "$TEMP_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
  tar -xf "$TEMP_DIR/sparkle.tar.xz" -C "$TEMP_DIR" ./bin/generate_appcast
  GEN_APPCAST="$TEMP_DIR/bin/generate_appcast"
fi

WORK_DIR=$(mktemp -d /tmp/appcast.XXXXXX)

cp "$ROOT/appcast.xml" "$WORK_DIR/appcast.xml"
cp "$ZIP" "$WORK_DIR/$ZIP_NAME"
cp "$NOTES_HTML" "$WORK_DIR/$ZIP_BASE.html"

pushd "$WORK_DIR" >/dev/null
"$GEN_APPCAST" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --link "$FEED_URL" \
  "$WORK_DIR"
popd >/dev/null

cp "$WORK_DIR/appcast.xml" "$ROOT/appcast.xml"

# Ensure the appcast item title matches the short version string.
perl -0pi -e '
  if (m{<item>.*?</item>}s) {
    my $item = $&;
    if ($item =~ m{<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>}s) {
      my $ver = $1;
      $item =~ s{<title>.*?</title>}{<title>$ver</title>}s;
      s{<item>.*?</item>}{$item}s;
    }
  }
' "$ROOT/appcast.xml"

echo "Appcast generated (appcast.xml). Upload alongside $ZIP at $FEED_URL"
