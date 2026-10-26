#!/usr/bin/env bash
#
# Download an Alien SlackBuild and, recursively, its dependencies.
# Files go to $SBDIR/<package>/build/ (default ~/slackbuilds).
#
# Usage: download-slackbuilds.sh <link to build/ dir>

SBDIR=${SBDIR:-$HOME/slackbuilds}

# slackware.com delays requests with the default wget user agent by ~8-10s;
# an honest, descriptive one is not delayed
USER_AGENT="download-slackbuilds.sh (Slackware user)"

if [ -z "$1" ]; then
    echo " Missing required link"
    echo " Example usage: $0 http://www.slackware.com/~alien/slackbuilds/amsynth/build/"
    echo " SlackBuilds dir: $SBDIR (override with SBDIR=...)"
    exit 1
fi

LINK=$1

download_build() {
    local LINK=$1 PACKAGE_NAME BASE_LINK BUILD_PATH DEPENDENCY_FILE line
    echo "Build to download: $LINK"

    # --cut-dirs=2 drops "~alien/slackbuilds", so files land in $SBDIR/<package>/build/
    # --reject-regex skips Apache's column-sort links (?C=N;O=D etc.), which
    # wget would otherwise download (8 extra requests per directory).
    # Source archives are skipped: the SlackBuild downloads the version it
    # builds from SRCURL. Compressed patches (*.diff.gz etc.) are still fetched.
    wget -r -N -np -nH --cut-dirs=2 -U "$USER_AGENT" -P "$SBDIR" \
        -R "index.html*,*.tar.*,*.tgz,*.tbz,*.tbz2,*.txz,*.zip,*.7z" \
        --reject-regex '\?C=' "$LINK"

    echo "Downloaded build: $LINK"

    PACKAGE_NAME=$(echo "$LINK" | awk -F '/' '{ print $(NF-2) }')
    echo "Package name: $PACKAGE_NAME"

    BASE_LINK=$(echo "$LINK" | awk -F "/$PACKAGE_NAME" '{ print $1 }')
    echo "Base link: $BASE_LINK"

    BUILD_PATH="$SBDIR/$PACKAGE_NAME/build"
    echo "Build path: $BUILD_PATH"

    DEPENDENCY_FILE="$BUILD_PATH/slack-required"

    if [[ -f "$DEPENDENCY_FILE" ]]; then
        echo "Dependency file: $DEPENDENCY_FILE exists. Dependencies:"
        cat "$DEPENDENCY_FILE"

        # First word of each line (lines may look like "pkg >= 1.0")
        while read -r line _; do
            if [ -n "$line" ]; then
                echo "Processing: $line"
                download_build "$BASE_LINK/$line/build/"
            fi
        done < "$DEPENDENCY_FILE"

    else
        echo "No dependencies file for $PACKAGE_NAME"
    fi
}

download_build "$LINK"
