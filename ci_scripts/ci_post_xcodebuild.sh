#!/bin/sh

set -e

# This branch always loads PersonalCloud.xcconfig, even when Xcode Cloud's environment
# lacks BP_SELF_HOSTED or still contains upstream credentials from an older workflow.
if [ -f "$(dirname "$0")/../BuildConfiguration/PersonalCloud.xcconfig" ] || [ "${BP_SELF_HOSTED:-NO}" = "YES" ] || [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
    exit 0
fi

# This is necessary in order to have sentry-cli
# install locally into the current directory
export INSTALL_DIR=$PWD

if [[ $(command -v sentry-cli) == "" ]]; then
    echo "Installing Sentry CLI"
    curl -sL https://sentry.io/get-cli/ | bash
fi

echo "Uploading dSYM to Sentry"

sentry-cli --auth-token "$SENTRY_AUTH_TOKEN" \
    upload-dif --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$CI_ARCHIVE_PATH"
