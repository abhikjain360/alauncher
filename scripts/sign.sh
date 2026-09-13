#!/usr/bin/env bash
# Signs an app bundle with the local identity from setup-signing.sh.
set -euo pipefail

source "$(dirname "$0")/signing-env.sh"

app=${1:?usage: sign.sh path/to/App.app}

if [[ ! -f "$SIGNING_KEYCHAIN" ]]; then
    echo "error: no signing identity; run scripts/setup-signing.sh once" >&2
    exit 1
fi

security unlock-keychain -p "$(cat "$SIGNING_PASSWORD_FILE")" "$SIGNING_KEYCHAIN"

# codesign only finds identities in keychains on the user search list, and a
# keychain left there can make other apps ask to unlock it after a reboot. So
# add it for this one signature and always put the original list back.
read_search_list
trap 'security list-keychains -d user -s "${search_list[@]}"' EXIT
security list-keychains -d user -s "${search_list[@]}" "$SIGNING_KEYCHAIN"

codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp=none "$app"
codesign --verify --strict "$app"
