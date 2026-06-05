#!/usr/bin/env bash
# Stamps the version from plugin.json into the pre-flight-check skill marker,
# and keeps the legacy compatibility shim in sync.
# Run this after bumping the version in plugin.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_DIR/.claude-plugin/plugin.json"
VERSION=$(jq -r .version "$PLUGIN_JSON")
SKILL="$REPO_DIR/skills/pre-flight-check/SKILL.md"

# Match the full standalone marker comment only, so the version string in prose
# (e.g. example "cofounder:begin COFOUNDER_VERSION: ..." markers) is never clobbered.
sed -i '' "s/<!-- COFOUNDER_VERSION: .* -->/<!-- COFOUNDER_VERSION: $VERSION -->/" "$SKILL"

echo "Stamped version $VERSION into $(basename "$SKILL")"

# Legacy compatibility shim. Clients installed before the root-level restructure
# (cofounder <= 0.21.10) run a pre-flight version check that fetches
# plugins/cofounder/.claude-plugin/plugin.json. Mirror the canonical manifest
# there so those clients still detect updates and get nudged to upgrade.
# Remove once pre-0.21.11 clients are no longer in the wild.
LEGACY_SHIM="$REPO_DIR/plugins/cofounder/.claude-plugin/plugin.json"
if [ -f "$LEGACY_SHIM" ]; then
  cp "$PLUGIN_JSON" "$LEGACY_SHIM"
  echo "Synced legacy shim at plugins/cofounder/.claude-plugin/plugin.json"
fi

# Gemini CLI extension manifest. Keep its version in sync with the canonical
# manifest so one bump drives every harness.
GEMINI_MANIFEST="$REPO_DIR/gemini-extension.json"
if [ -f "$GEMINI_MANIFEST" ]; then
  tmp=$(mktemp)
  jq --arg v "$VERSION" '.version = $v' "$GEMINI_MANIFEST" > "$tmp" && mv "$tmp" "$GEMINI_MANIFEST"
  echo "Synced gemini-extension.json to $VERSION"
fi
