#!/usr/bin/env bash

if [ -z "$1" ]; then
    echo " Missing required link"
    echo " Example usage: $0 http://www.slackware.com/~alien/slackbuilds/amsynth/build/"
    exit 1
fi

LINK=$1

download_build() {
    local LINK=$1
    echo "Build to download: $LINK"

    wget -r -N -np -nH --cut-dirs=1 -R "index.html*" $LINK
    # wget -r -N -np -nH --cut-dirs=1 $LINK

    echo "Downloaded build: $LINK"

    PACKAGE_NAME=$(echo $LINK | awk -F '/' '{ print $(NF-2) }')
    echo "Package name: $PACKAGE_NAME"

    BASE_LINK=$(echo $LINK | awk -F "/$PACKAGE_NAME" '{ print $1 }')
    echo "Base link: $BASE_LINK"

    BUILD_PATH=$(echo $LINK | awk -F '/' '{ print $(NF-3) "/" $(NF-2) "/" $(NF-1) }')
    echo "Build path: $BUILD_PATH"

    DEPENDENCY_FILE="$BUILD_PATH/slack-required"

    if [[ -f "$DEPENDENCY_FILE" ]]; then
        echo "Dependency file: $DEPENDENCY_FILE exixts. Dependencies:"
        cat "$DEPENDENCY_FILE"

        # Loop through each line
        while IFS= read -r line; do
            if [ $line ]; then
                echo "Processing: $line"
                DEP_LINK="$BASE_LINK/$line/build/"
                echo "Dependency link: $DEP_LINK"
                download_build $DEP_LINK
            fi

        done < "$DEPENDENCY_FILE"

    else
        echo "No dependencies file for $PACKAGE_NAME"
    fi
}

download_build $LINK
