#!/usr/bin/env bash
#
# Build (and optionally install) SlackBuilds fetched with download-slackbuilds.sh.
#
# Usage: build-slackbuild.sh [-c] [-d] [-f] [-i] [-n] [-V version] <package>

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SBDIR=${SBDIR:-$SCRIPT_DIR/slackbuilds}
OUTPUT=${OUTPUT:-/tmp}
export OUTPUT
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}

usage() {
    cat <<EOF
Usage: $0 [-c] [-d] [-f] [-i] [-n] [-V version] <package>
  -c          check only: show versions (incl. upstream), do not build
  -d          also process dependencies from slack-required, recursively;
              missing or outdated dependencies are built and installed first
  -f          rebuild <package> even if this version is already installed
  -i          install/upgrade <package> after a successful build
  -n          build the newest upstream version instead of the SlackBuild default
  -V version  build this exact version of <package>
SlackBuilds dir: $SBDIR (override with SBDIR=...)
EOF
    exit 1
}

CHECK_ONLY=0
DEPS=0
FORCE=0
INSTALL=0
NEWEST=0
USER_VER=
while getopts "cdfinV:h" opt; do
    case $opt in
        c) CHECK_ONLY=1 ;;
        d) DEPS=1 ;;
        f) FORCE=1 ;;
        i) INSTALL=1 ;;
        n) NEWEST=1 ;;
        V) USER_VER=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage

if [ $CHECK_ONLY -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: building requires root, e.g.: su -c '$0 $*'"
    exit 1
fi

# Escape a string for use in an extended regex (and as a sed pattern)
re_escape() {
    printf '%s' "$1" | sed 's/[][\.*^$()+?{}|/]/\\&/g'
}

# Return 0 if version $1 is greater than version $2
ver_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Installed version of a package name, empty if not installed
installed_version() {
    ls "$PKGDB" 2>/dev/null \
        | grep -E "^$(re_escape "$1")-[^-]+-[^-]+-[^-]+$" \
        | sed -E 's/.*-([^-]+)-[^-]+-[^-]+$/\1/' | head -n1
}

# SRCURL from SlackBuild $1, with @VERSION@ in place of the version
srcurl_template() {
    local vars
    vars=$(awk '/^SRCURL(\[0\])?=/ { sub(/^SRCURL\[0\]=/, "SRCURL="); print; exit }
                /^[A-Za-z_][A-Za-z0-9_]*=/ { print }' "$1")
    ( VERSION=@VERSION@; eval "$vars" 2>/dev/null; printf '%s\n' "${SRCURL:-}" )
}

# Read text on stdin, print versions found as <prefix>VERSION<suffix>
extract_versions() {
    local pre suf
    pre=$(re_escape "$1")
    suf=$(re_escape "$2")
    grep -oE "${pre}[0-9]+(\.[0-9]+)*${suf}" | sed -E "s/^${pre}//; s/${suf}\$//"
}

# Latest stable version from the source site of a SRCURL template
latest_upstream() {
    local tpl=$1 file pre suf path
    case $tpl in *@VERSION@*) ;; *) return 1 ;; esac
    file=${tpl##*/}
    pre=${file%%@VERSION@*}
    suf=${file#*@VERSION@}
    case $tpl in
        *://github.com/*|*://codeload.github.com/*)
            # Latest published release (no tags: old/odd tags give wrong results)
            wget -qO- "https://api.github.com/repos/$(echo "$tpl" | cut -d/ -f4-5)/releases/latest" \
                | sed -nE 's/.*"tag_name": *"[^0-9"]*([0-9]+(\.[0-9]+)*)".*/\1/p'
            ;;
        *sourceforge.net/*)
            path=${tpl#*sourceforge.net/}
            path=${path#project/}
            wget -qO- "https://sourceforge.net/projects/${path%%/*}/rss?path=/" \
                | extract_versions "$pre" "$suf"
            ;;
        *)
            path=${tpl%/*}
            case $path in *@VERSION@*) return 1 ;; esac
            # Need a file extension after the version, or the match is unreliable
            [ -n "$suf" ] || return 1
            wget -qO- "$path/" | extract_versions "$pre" "$suf"
            ;;
    esac | sort -uV | tail -n1
}

# Fallback: newest version known to repology.org (tracks most distros)
repology_version() {
    wget -qO- "https://repology.org/api/v1/project/$1" \
        | grep -oE '\{[^{}]*\}' | grep -E '"status": *"newest"' \
        | sed -nE 's/.*"version": *"([^"]+)".*/\1/p' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -uV | tail -n1
}

VISITED=" "

# Process one package: show info, handle deps (with -d), then build.
# $1 = package, $2 = parent package (empty for the top-level one)
process_pkg() {
    local pkg=$1 parent=$2
    local build_dir=$SBDIR/$1/build
    local sb_file=$build_dir/$1.SlackBuild
    local prgnam sb_ver inst_ver latest from target pkgfile dep need_build=1
    local -a deps=()

    case $VISITED in *" $pkg "*) return 0 ;; esac
    VISITED="$VISITED$pkg "

    echo
    if [ -n "$parent" ]; then
        echo "== $pkg (dependency of $parent)"
    else
        echo "== $pkg"
    fi

    if [ ! -f "$sb_file" ]; then
        inst_ver=$(installed_version "$pkg")
        if [ -n "$inst_ver" ]; then
            echo "Installed version:  $inst_ver (no SlackBuild downloaded, skipping)"
            return 0
        fi
        echo "ERROR: $sb_file not found. Download it first, e.g.:"
        echo "  $SCRIPT_DIR/download-slackbuilds.sh http://www.slackware.com/~alien/slackbuilds/$pkg/build/"
        return 1
    fi

    prgnam=$(sed -nE 's/^PRGNAM=//p' "$sb_file" | head -n1 | tr -d '"')
    prgnam=${prgnam:-$pkg}
    sb_ver=$(sed -nE 's/^VERSION=\$\{VERSION:-(.*)\}.*/\1/p' "$sb_file" | head -n1 | tr -d '"')
    inst_ver=$(installed_version "$prgnam")

    echo "SlackBuild version: ${sb_ver:-unknown}"
    echo "Installed version:  ${inst_ver:-not installed}"

    target=$sb_ver
    if [ -z "$parent" ] && [ -n "$USER_VER" ]; then
        target=$USER_VER
    elif [ $NEWEST -eq 1 ] || [ $CHECK_ONLY -eq 1 ]; then
        latest=$(latest_upstream "$(srcurl_template "$sb_file")")
        from="source site"
        if [ -z "$latest" ]; then
            latest=$(repology_version "$prgnam")
            from="repology.org"
        fi
        if [ -n "$latest" ]; then
            echo "Upstream version:   $latest (from $from)"
        else
            echo "Upstream version:   could not detect automatically"
        fi
        if [ $NEWEST -eq 1 ] && [ -n "$latest" ] && ver_gt "$latest" "$sb_ver"; then
            target=$latest
        fi
    fi

    if [ -z "$target" ]; then
        echo "ERROR: no version to build for $pkg, use -V <version>"
        return 1
    fi
    echo "Version to build:   $target"

    if [ -n "$inst_ver" ] && ! ver_gt "$target" "$inst_ver"; then
        if [ -z "$parent" ] && [ $FORCE -eq 1 ]; then
            echo "Already installed, rebuilding (-f)."
        else
            echo "Installed version is up to date."
            need_build=0
        fi
    fi

    # Dependencies: process them with -d, otherwise just warn
    if [ -f "$build_dir/slack-required" ]; then
        mapfile -t deps < <(awk '!/^#/ && NF { print $1 }' "$build_dir/slack-required")
    fi
    for dep in "${deps[@]}"; do
        if [ $DEPS -eq 1 ]; then
            process_pkg "$dep" "$pkg" || [ $CHECK_ONLY -eq 1 ] || return 1
        elif [ -z "$(installed_version "$dep")" ]; then
            echo "WARNING: dependency not installed: $dep"
        fi
    done

    [ $need_build -eq 1 ] || return 0
    [ $CHECK_ONLY -eq 1 ] && return 0

    echo
    echo "== Building $prgnam $target in $build_dir ..."
    ( cd "$build_dir" && VERSION=$target bash "./$pkg.SlackBuild" )

    pkgfile=$(ls -t "$OUTPUT/$prgnam-$target-"*.t?z 2>/dev/null | head -n1)
    if [ -z "$pkgfile" ]; then
        echo "ERROR: build failed, no $prgnam-$target package in $OUTPUT"
        return 1
    fi
    echo "Package created: $pkgfile"

    # Dependencies are always installed (needed to build the parent)
    if [ -n "$parent" ] || [ $INSTALL -eq 1 ]; then
        upgradepkg --install-new "$pkgfile" || return 1
    else
        echo "Install with: upgradepkg --install-new $pkgfile"
    fi
}

process_pkg "$1" ""
