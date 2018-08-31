#!/usr/bin/env bash

set -euo pipefail

# This will be set to 1 if we instruct the user to manually verify signatures,
# when they have GPG but don't have the BinTray public key. Would be super confusing
# to tell the user to use files that we've cleaned up.
DO_CLEANUP=0

color_title=$(tput setaf 7; tput bold)
color_dim=$(tput setaf 8)
color_good=$(tput setaf 2)
color_bad=$(tput setaf 1)
color_warn=$(tput setaf 3)
color_reset=$(tput sgr0)

usage() {
    cat <<EOF
${color_title}$0${color_reset}
Downloads the latest version of the Zipkin Server executable jar

${color_title}$0 GROUP:ARTIFACT:VERSION:CLASSIFIER TARGET${color_reset}
Downloads the "VERSION" version of GROUP:ARTIFACT with classifier "CLASSIFIER"
to path "TARGET" on the local file system. "VERSION" can take the special value
"LATEST", in which case the latest Zipkin release will be used. For example:

${color_title}$0 io.zipkin.aws:zipkin-autoconfigure-collector-kinesis:LATEST:module kinesis.jar${color_reset}
downloads the latest version of the artifact with group "io.zipkin.aws",
artifact id "zipkin-autoconfigure-collector-kinesis", and classifier "module"
to PWD/kinesis.jar
EOF
}

welcome() {
    cat <<EOF
${color_title}Thank you for trying OpenZipkin!${color_reset}
This installer is provided as a quick-start helper, so you can try Zipkin out
without a lengthy installation process.

EOF
}

farewell() {
    local artifact_classifier="$1"; shift
    local filename="$1"; shift
    echo -n "$color_good"
    if [ "$artifact_classifier" = 'exec' ]; then
        cat <<EOF

You can now run the downloaded executable jar:

    java -jar $filename

EOF
    else
        cat << EOF

The downloaded artifact is now available at $filename.
EOF
    fi
    echo -n "$color_reset"
}

handle_shutdown() {
    local status=$?
    local base_filename="$1"; shift
    if [ $status -eq 0 ]; then
        if [ "$DO_CLEANUP" -eq 0 ]; then
            rm -f "$base_filename"{.md5,.asc,.md5.asc}
        fi
    else
        cat <<EOF
${color_bad}
It looks like quick-start setup has failed. Please run the command again
with the debug flag like below, and open an issue on
https://github.com/openzipkin/zipkin/issues/new. Make sure to include the
full output of the run.
${color_reset}
    \\curl -sSL http://zipkin.io/quickstart.sh | bash -sx -- $@

In the meanwhile, you can manually download and run the latest executable jar
from the following URL:

https://dl.bintray.com/openzipkin/maven/io/zipkin/java/zipkin-server/
EOF
    fi
}

execute_and_log() {
    local command=("$@")
    echo >&2 "${color_dim}> ${command[*]}${color_reset}"
    eval "${command[@]}"
}

fetch() {
    url="$1"; shift
    target="$1"; shift
    execute_and_log curl -fL -o "'$target'" "'$url'"
}

fetch_latest_version() {
    local artifact_group="$1"; shift
    local artifact_id="$1"; shift
    local url="https://api.bintray.com/search/packages/maven?g=${artifact_group}&a=${artifact_id}&subject=openzipkin"
    local package_data
    local package_count
    local have_jq

    # We'll have more robustness if jq is present, but will do our best without it as well
    if command -v jq >/dev/null 2>&1; then
        have_jq=true
    else
        have_jq=false
        echo >&2 "${color_warn}jq not found on path. This script will still do its best, but installing jq"
        echo >&2 "will allow it to parse data from Bintray in a more robust fashion.${color_reset}"
    fi

    # Call the Bintray API to search for releases
    package_data="$(execute_and_log curl -SL "'$url'")"

    # Count how many packages we got from the search
    if $have_jq; then
        package_count="$(echo "$package_data" | jq length)"
    else
        package_count="$(echo "$package_data" | tr , '\n' | grep -c latest_version)"
    fi
    # We want exactly one result.
    if [ "$package_count" -eq 0 ]; then
        echo >&2 "${color_bad}No package information found; the provided group or artifact ID may be invalid.${color_reset}"
        exit 1
    elif [ "$package_count" -gt 1 ]; then
        echo >&2 "${color_bad}More than one package returned from search by Maven group and artifact ID.${color_reset}"
        exit 1
    fi

    # Finally, extract the actual package version
    if $have_jq; then
        echo "$package_data" | jq '.[0].latest_version' -r
    else
        echo "$package_data" | tr , '\n' | grep latest_version | sed 's/^.*"latest_version" *: *"*\([^"]*\)".*$/\1/'
    fi
}

artifact_part() {
    local index="$1"; shift
    cut -f "$index" -d:
}

verify_version_number() {
    if ! echo "$1" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null 2>&1; then
        cat <<EOF
${color_bad}The target version is "$1". That doesn't look like a valid Zipkin release version
number; this script is confused. Bailing out.
${color_reset}
EOF
        exit 1
    fi
}

verify_checksum() {
    local url="$1"; shift
    local filename="$1"; shift

    # Fetch the .md5 file even if md5sum is not on the path
    # This lets us verify its GPG signature later on, and the user might have another way of checksum verification
    fetch "$url.md5" "$filename.md5"

    if command -v md5sum >/dev/null 2>&1; then
        echo
        echo "${color_title}Verifying checksum...${color_reset}"
        execute_and_log "echo \"\$(cat $filename.md5)  $filename\" | md5sum --check"
        echo "${color_good}Checksum for ${filename} passes verification${color_reset}"
    else
        echo "${color_warn}md5sum not found on path, skipping checksum verification${color_reset}"
    fi
}

verify_signature() {
    local url="$1"; shift
    local filename="$1"; shift

    local bintray_gpg_key='D401AB61'

    if command -v gpg >/dev/null 2>&1; then
        echo
        echo "${color_title}Verifying GPG signature of $filename...${color_reset}"
        fetch "$url.asc" "$filename.asc"
        if gpg --list-keys "$bintray_gpg_key" >/dev/null 2>&1; then
            execute_and_log gpg --verify "$filename.asc" "$filename"
            echo "${color_good}GPG signature for ${filename} passes verification${color_reset}"
        else
            cat <<EOF
${color_warn}
JFrog BinTray GPG signing key is not known, skipping signature verification.
You can import it, then verify the signature of $filename, using the following
commands:

    gpg --keyserver keyserver.ubuntu.com --recv $bintray_gpg_key
    # Optionally trust the key via 'gpg --edit-key $bintray_gpg_key', then typing 'trust',
    # choosing a trust level, and exiting the interactive GPG session by 'quit'
    gpg --verify $filename.asc $filename
${color_reset}
EOF
            DO_CLEANUP=1
        fi
    else
        echo "${color_warn}gpg not found on path, skipping checksum verification${color_reset}"
    fi
}

main() {
    local artifact_group=io.zipkin.java
    local artifact_id=zipkin-server
    local artifact_version=LATEST
    local artifact_version_lowercase=latest
    local artifact_classifier=exec
    local artifact_group_with_slashes
    local artifact_url

    if [ $# -eq 0 ]; then
        local filename="zipkin.jar"
        # shellcheck disable=SC2064
        trap "handle_shutdown \"$filename\" $*" EXIT
    elif [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
        usage
        exit
    elif [ $# -eq 2 ]; then
        local filename="$2"
        # shellcheck disable=SC2064
        trap "handle_shutdown \"$filename\" $*" EXIT
        artifact_group="$(echo "$1" | artifact_part 1)"
        artifact_id="$(echo "$1" | artifact_part 2)"
        artifact_version="$(echo "$1" | artifact_part 3)"
        artifact_classifier="$(echo "$1" | artifact_part 4)"
    else
        usage
        exit 1
    fi

    if [ -n "$artifact_classifier" ]; then
        artifact_classifier_suffix="-$artifact_classifier"
    else
        artifact_classifier_suffix=''
    fi

    welcome

    artifact_version_lowercase="$(echo "${artifact_version}" | tr '[:upper:]' '[:lower:]')"
    if [  "${artifact_version_lowercase}" = 'latest' ]; then
        echo "${color_title}Fetching version number of latest ${artifact_group}:${artifact_id} release...${color_reset}"
        artifact_version="$(fetch_latest_version "$artifact_group" "$artifact_id")"
    fi
    verify_version_number "$artifact_version"
    echo "${color_good}Latest release of ${artifact_group}:${artifact_id} seems to be ${artifact_version}${color_reset}"
    echo

    echo "${color_title}Downloading $artifact_group:$artifact_id:$artifact_version:$artifact_classifier to $filename...${color_reset}"
    artifact_group_with_slashes="$(echo "${artifact_group}" | tr '.' '/')"
    artifact_url="https://dl.bintray.com/openzipkin/maven/${artifact_group_with_slashes}/${artifact_id}/$artifact_version/${artifact_id}-${artifact_version}${artifact_classifier_suffix}.jar"
    fetch "$artifact_url" "$filename"
    verify_checksum "$artifact_url" "$filename"
    verify_signature "$artifact_url" "$filename"
    verify_signature "$artifact_url.md5" "$filename.md5"

    farewell "$artifact_classifier" "$filename"
}

main "$@"
