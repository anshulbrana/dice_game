#!/usr/bin/env bash
# Usage: publish_artifact.sh <artifact_file> <artifact_name> <tag> <release_name>
# Env:   GITHUB_TOKEN, GITHUB_OWNER (optional, auto-detected), GITHUB_REPO
#
# Example:
#   GITHUB_TOKEN=xxx GITHUB_REPO=dice_game \
#   publish_artifact.sh app-release.aab dice_game.aab build-42 "Build #42"

set -e

ARTIFACT_FILE="$1"
ARTIFACT_NAME="$2"
TAG="$3"
RELEASE_NAME="$4"

if [ -z "$ARTIFACT_FILE" ] || [ -z "$ARTIFACT_NAME" ] || [ -z "$TAG" ] || [ -z "$RELEASE_NAME" ]; then
  echo "❌ Usage: $0 <artifact_file> <artifact_name> <tag> <release_name>"
  exit 1
fi

if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "❌ Artifact file not found: $ARTIFACT_FILE"
  exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "❌ GITHUB_TOKEN is not set"
  exit 1
fi

if [ -z "$GITHUB_REPO" ]; then
  echo "❌ GITHUB_REPO is not set"
  exit 1
fi

# Auto-detect owner if not provided
if [ -z "$GITHUB_OWNER" ]; then
  USER_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user)
  echo "GitHub user response: $USER_RESPONSE"
  GITHUB_OWNER=$(echo "$USER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])")
fi

echo "Owner: $GITHUB_OWNER, Repo: $GITHUB_REPO, Tag: $TAG"

# Get existing release by tag, or create new one
RELEASE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/tags/$TAG")
echo "Existing release response: $RELEASE"
RELEASE_ID=$(echo "$RELEASE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

if [ -z "$RELEASE_ID" ]; then
  echo "No existing release found, creating new one..."
  RELEASE=$(curl -s -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"$RELEASE_NAME\",\"draft\":false,\"prerelease\":true}" \
    "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases")
  echo "Create release response: $RELEASE"
fi

UPLOAD_URL=$(echo "$RELEASE" | python3 -c "import sys,json; print(json.load(sys.stdin)['upload_url'])" | sed 's/{.*//')
echo "Upload URL: $UPLOAD_URL"

# Upload artifact (300s timeout, show progress)
UPLOAD_RESPONSE=$(curl -S --max-time 300 --retry 2 --retry-delay 5 -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  "${UPLOAD_URL}?name=${ARTIFACT_NAME}" \
  --data-binary @"$ARTIFACT_FILE")
echo "Upload response: $UPLOAD_RESPONSE"

DOWNLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['browser_download_url'])")
echo "✅ $ARTIFACT_NAME available at: $DOWNLOAD_URL"

# Export as Harness output variable (visible in pipeline UI and usable by subsequent steps)
# Format: https://developer.harness.io/docs/continuous-integration/use-ci/run-step-settings/#output-variables
SANITIZED_NAME=$(echo "$ARTIFACT_NAME" | tr '.' '_')
echo "DOWNLOAD_URL_${SANITIZED_NAME}=$DOWNLOAD_URL" >> "$DRONE_OUTPUT" 2>/dev/null || true

# Publish to Harness Artifacts tab using the artifact-metadata-publisher binary
# Required for hosted macOS runners (cannot use containerized Plugin step)
# See: https://developer.harness.io/docs/continuous-integration/use-ci/build-and-upload-artifacts/artifacts-tab/#using-the-plugin-binary-on-hosted-macos-runners
PUBLISHER_BINARY="./artifact-metadata-publisher"
if [ ! -f "$PUBLISHER_BINARY" ]; then
  echo "Downloading artifact-metadata-publisher binary..."
  curl -sL https://github.com/drone-plugins/artifact-metadata-publisher/releases/download/v2.2.0/artifact-metadata-publisher-darwin-arm64.zst \
    -o artifact-metadata-publisher-darwin-arm64.zst
  zstd -d artifact-metadata-publisher-darwin-arm64.zst -o "$PUBLISHER_BINARY"
  chmod 700 "$PUBLISHER_BINARY"
fi

echo "Publishing to Harness Artifacts tab..."
PLUGIN_FILE_URLS="${ARTIFACT_NAME}:::${DOWNLOAD_URL}" "$PUBLISHER_BINARY"
echo "✅ Published to Harness Artifacts tab"
