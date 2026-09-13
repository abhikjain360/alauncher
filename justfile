# alauncher tasks. Swift, the SDK and codesign come from Xcode.

app := env_var('HOME') / "Applications/alauncher.app"

default: build

# One-time: create the local code-signing identity.
setup-signing:
    scripts/setup-signing.sh

# Build and sign build/alauncher.app (config: debug or release).
build config="release":
    scripts/build-app.sh {{config}}

# Build, then replace the installed app and restart it.
install config="release": (build config)
    -pkill -x alauncher
    mkdir -p "{{parent_directory(app)}}"
    rsync -a --delete build/alauncher.app/ "{{app}}/"
    open "{{app}}"

# Run all unit tests.
test:
    xcrun swift test --package-path Packages/Calc
    xcrun swift test --package-path Packages/Search
    xcrun swift test

# Follow the app log.
logs:
    tail -F ~/Library/Logs/alauncher/alauncher.log
