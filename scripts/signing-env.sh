# shellcheck shell=bash disable=SC2034
# Shared by setup-signing.sh and sign.sh.
SIGNING_IDENTITY="alauncher Local Signing"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/alauncher-signing.keychain-db"
SIGNING_DIR="$HOME/Library/Application Support/alauncher/signing"
SIGNING_PASSWORD_FILE="$SIGNING_DIR/keychain-password"

# Fills the array `search_list` with the user keychain search list, minus the
# signing keychain.
read_search_list() {
    search_list=()
    local line
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        line=${line#\"}
        line=${line%\"}
        [[ -n "$line" && "$line" != "$SIGNING_KEYCHAIN" ]] && search_list+=("$line")
    done < <(security list-keychains -d user)
}
