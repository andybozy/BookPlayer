#!/bin/sh
# Runs in both app targets with Xcode's resolved build settings, without printing secrets.
set -eu

fail() {
    printf 'error: Personal BookPlayer build: %s See SELFHOSTED.md.\n' "$1" >&2
    exit 1
}

[ "${BP_SELF_HOSTED:-}" = YES ] || fail 'BP_SELF_HOSTED must be YES; remove a conflicting target or command-line override.'
[ "${BP_API_SCHEME:-}" = https ] || fail 'BP_API_SCHEME must be https.'
[ "${BP_API_DOMAIN:-}" = bookplayer.androshera.xyz ] || fail 'BP_API_DOMAIN must point to the configured personal server.'
[ -z "${BP_API_PORT:-}" ] || fail 'BP_API_PORT must be empty for the HTTPS tunnel.'
[ "${BP_ENTITLEMENTS:-}" = BookPlayer-SelfHosted ] || fail 'Select the personal iOS entitlements.'
[ "${BP_WATCH_ENTITLEMENTS:-}" = BookPlayerWatch-SelfHosted ] || fail 'Select the personal Watch entitlements.'
[ -z "${BP_MOCKED_BEARER_TOKEN:-}" ] || fail 'BP_MOCKED_BEARER_TOKEN must be empty.'
[ -z "${BP_REVENUECAT_KEY:-}" ] || fail 'RevenueCat must be disabled for this personal build.'
[ -z "${BP_SENTRY_DSN:-}" ] || fail 'Sentry must be disabled for this personal build.'

printf '%s\n' 'Personal cloud configuration verified (username/password login).'
