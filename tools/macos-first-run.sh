#!/usr/bin/env bash
# First-run helper for the unsigned JBUpdater.app on macOS.
#
# The app is not Apple-notarized, so Gatekeeper quarantines it on
# download. This script clears the quarantine flag and (optionally)
# applies an ad-hoc signature so the app launches with a double-click.
#
# Usage:
#   ./tools/macos-first-run.sh [/path/to/JBUpdater.app]
set -euo pipefail

APP="${1:-/Applications/JBUpdater.app}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found" >&2
  echo "usage: $0 [/path/to/JBUpdater.app]" >&2
  exit 1
fi

echo "→ Clearing quarantine flag on $APP ..."
xattr -cr "$APP"

echo "→ Applying ad-hoc signature ..."
codesign --force --deep --sign - "$APP" 2>/dev/null || {
  echo "warning: codesign failed (continuing without signature)" >&2
}

echo "→ Verifying ..."
codesign --verify --deep --strict "$APP" 2>&1 | head -3 || true
spctl --assess --type execute "$APP" 2>&1 || {
  echo "note: spctl assessment failed — first launch may still ask for"
  echo "confirmation. Right-click the app → Open → Open to allow it once."
}

echo "Done. Launch with: open \"$APP\""
