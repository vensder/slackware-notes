#!/usr/bin/env bash
#
# Build (and optionally install) SlackBuilds fetched with download-slackbuilds.sh.
#
# Usage: build-slackbuild.sh [-cdfinqv] [-V version] <package>
#        build-slackbuild.sh -a [-cdfinqv]    (all installed packages tagged "alien")

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# Default: ~/slackbuilds of the real user, also when run via su/sudo
# (where $HOME may point to /root). Override with SBDIR=...
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null)}
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
SBDIR=${SBDIR:-${REAL_HOME:-$HOME}/slackbuilds}
OUTPUT=${OUTPUT:-/tmp}
export OUTPUT
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
# Build tag of the packages handled by -a
PKGTAG=${PKGTAG:-alien}
# Packages on hold (one name per line, # comments): skipped by -a and -d,
# built only when named directly. E.g. carla kept at a stable release while
# the SlackBuild default is a newer-sorting git snapshot.
HOLD_FILE=${HOLD_FILE:-$SBDIR/.hold}

usage() {
    cat <<EOF
Usage: $0 [-cdfinqv] [-V version] <package>
       $0 -a [-cdfinqv]
  -a          all installed packages with build tag "$PKGTAG" (instead of <package>);
              -a -c checks them all, -a -n -i upgrades them to newest upstream
  -c          check only: show versions (incl. upstream), do not build
  -d          also process dependencies from slack-required, recursively;
              missing or outdated dependencies are built and installed first
  -f          rebuild <package> even if this version is already installed
  -i          install/upgrade <package> after a successful build
  -n          build the newest upstream version instead of the SlackBuild default
  -q          quiet: send SlackBuild output to a log file in $OUTPUT
              (shows the last lines on failure)
  -v          verbose: show URLs requested by the upstream version check
  -V version  build this exact version of <package>
SlackBuilds dir: $SBDIR (override with SBDIR=...)
Hold list:       $HOLD_FILE (skipped by -a/-d; override with HOLD_FILE=...)
EOF
    exit 1
}

ALL=0
CHECK_ONLY=0
DEPS=0
FORCE=0
INSTALL=0
NEWEST=0
QUIET=0
VERBOSE=0
USER_VER=
while getopts "acdfinqvV:h" opt; do
    case $opt in
        a) ALL=1 ;;
        c) CHECK_ONLY=1 ;;
        d) DEPS=1 ;;
        f) FORCE=1 ;;
        i) INSTALL=1 ;;
        n) NEWEST=1 ;;
        q) QUIET=1 ;;
        v) VERBOSE=1 ;;
        V) USER_VER=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
if [ $ALL -eq 1 ]; then
    [ $# -eq 0 ] || usage
    if [ -n "$USER_VER" ]; then
        echo "ERROR: -V can't be used with -a"
        exit 1
    fi
else
    [ $# -eq 1 ] || usage
fi

if [ $CHECK_ONLY -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: building requires root, e.g.: su -c '$0 $*'"
    exit 1
fi

# Download a URL to stdout for the version check. Short timeout and one retry,
# so an unresponsive site can't hang the run (wget default: 900s, 20 tries)
fetch() {
    [ $VERBOSE -eq 1 ] && echo "  fetching: $1" >&2
    wget -qO- -T 15 -t 2 "$1"
}

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

# Evaluate the top-level "VAR=..." lines of a SlackBuild one by one (so a
# multi-line assignment can't break the rest), stopping after the line that
# sets variable $2. Prints that variable's value. Runs in a subshell.
# $3: initial value of VERSION (empty = unset)
sb_eval_var() {
    local file var=$2 init=$3
    file=$(readlink -f "$1")
    (
        # Run in the build dir like the SlackBuild itself (some derive
        # VERSION from the tarball there, e.g. VERSION=$(ls *.tar.* ...))
        cd "$(dirname "$file")" || exit
        unset VERSION
        [ -n "$init" ] && VERSION=$init
        while IFS= read -r line; do
            # $0 is the SlackBuild when it runs, not this script
            line=${line//\$\{0\}/$file}
            line=${line//\$0/$file}
            # skip lines that don't parse alone (would abort the subshell)
            bash -n -c "$line" 2>/dev/null && eval "$line" 2>/dev/null
        done < <(awk -v v="$var" '
            $0 ~ "^" v "(\\[0\\])?=" { sub("^" v "\\[0\\]=", v "="); print; exit }
            /^[A-Za-z_][A-Za-z0-9_]*=/ { print }' "$file")
        printf '%s\n' "${!var}"
    )
}

# Default VERSION of SlackBuild $1, with variables resolved, e.g.
# VERSION=${VERSION:-${MINGW}_gcc${GCC}} -> v11.0.0_gcc13.1.0
sb_version() {
    sb_eval_var "$1" VERSION ""
}

# SRCURL from SlackBuild $1, with @VERSION@ in place of the version
srcurl_template() {
    sb_eval_var "$1" SRCURL @VERSION@
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
            fetch "https://api.github.com/repos/$(echo "$tpl" | cut -d/ -f4-5)/releases/latest" \
                | sed -nE 's/.*"tag_name": *"[^0-9"]*([0-9]+(\.[0-9]+)*)".*/\1/p'
            ;;
        *sourceforge.net/*)
            path=${tpl#*sourceforge.net/}
            path=${path#project/}
            fetch "https://sourceforge.net/projects/${path%%/*}/rss?path=/" \
                | extract_versions "$pre" "$suf"
            ;;
        *)
            path=${tpl%/*}
            case $path in *@VERSION@*) return 1 ;; esac
            # Need a file extension after the version, or the match is unreliable
            [ -n "$suf" ] || return 1
            fetch "$path/" | extract_versions "$pre" "$suf"
            ;;
    esac | sort -uV | tail -n1
}

# Fallback: newest version known to repology.org (tracks most distros)
repology_version() {
    fetch "https://repology.org/api/v1/project/$1" \
        | grep -oE '\{[^{}]*\}' | grep -E '"status": *"newest"' \
        | sed -nE 's/.*"version": *"([^"]+)".*/\1/p' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -uV | tail -n1
}

VISITED=" "
HELD=()       # packages skipped because they are on hold

# Return 0 if package $1 is listed in the hold file
on_hold() {
    [ -f "$HOLD_FILE" ] && sed 's/#.*//' "$HOLD_FILE" | awk '{ print $1 }' | grep -qxF -- "$1"
}
UPDATES=()    # "name: installed -> upstream", for the -a summary
NOSB=()       # installed packages without a downloaded SlackBuild

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

    if { [ -n "$parent" ] || [ $ALL -eq 1 ]; } && on_hold "$pkg"; then
        echo
        echo "== $pkg: on hold ($HOLD_FILE), skipping (installed: $(installed_version "$pkg"))"
        HELD+=("$pkg")
        return 0
    fi

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
            NOSB+=("$pkg")
            return 0
        fi
        echo "ERROR: $sb_file not found. Download it first, e.g.:"
        echo "  $SCRIPT_DIR/download-slackbuilds.sh http://www.slackware.com/~alien/slackbuilds/$pkg/build/"
        return 1
    fi

    prgnam=$(sed -nE 's/^PRGNAM=//p' "$sb_file" | head -n1 | tr -d '"')
    prgnam=${prgnam:-$pkg}
    sb_ver=$(sb_version "$sb_file")
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
            if [ -n "$inst_ver" ] && ver_gt "$latest" "$inst_ver"; then
                UPDATES+=("$prgnam: $inst_ver -> $latest")
            fi
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
    local log=$OUTPUT/build-$prgnam-$target.log
    local stamp
    stamp=$(mktemp)
    # Pass VERSION only when it differs from the SlackBuild default: some
    # SlackBuilds (e.g. git snapshots) behave differently when it is preset
    local -a run_env=()
    [ "$target" != "$sb_ver" ] && run_env=("VERSION=$target")
    if [ $QUIET -eq 1 ]; then
        echo "Build log: $log (follow with: tail -f $log)"
        ( cd "$build_dir" && env "${run_env[@]}" bash "./$pkg.SlackBuild" ) > "$log" 2>&1
    else
        ( cd "$build_dir" && env "${run_env[@]}" bash "./$pkg.SlackBuild" )
    fi

    # Only accept a package created by this build, not one left from earlier
    pkgfile=$(find "$OUTPUT" -maxdepth 1 -name "$prgnam-$target-*.t?z" -newer "$stamp" | head -n1)
    rm -f "$stamp"
    if [ -z "$pkgfile" ]; then
        if [ $QUIET -eq 1 ]; then
            echo "---- last 30 lines of $log ----"
            tail -n 30 "$log"
            echo "----"
        fi
        echo "ERROR: build failed, no new $prgnam-$target package in $OUTPUT"
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

if [ $ALL -eq 0 ]; then
    process_pkg "$1" ""
    exit
fi

# -a: every installed package whose build field ends with the tag (e.g. 1alien).
# Names are what is left after stripping the version, arch and build fields.
FAILED=()
for p in $(ls "$PKGDB" | grep -E -- "-[0-9]+$(re_escape "$PKGTAG")\$" | rev | cut -d- -f4- | rev); do
    process_pkg "$p" "" || FAILED+=("$p")
done

echo
echo "== Summary"
if [ $NEWEST -eq 1 ] || [ $CHECK_ONLY -eq 1 ]; then
    if [ ${#UPDATES[@]} -gt 0 ]; then
        echo "Newer upstream versions:"
        printf '  %s\n' "${UPDATES[@]}"
    else
        echo "No newer upstream versions found."
    fi
fi
if [ ${#NOSB[@]} -gt 0 ]; then
    echo "Skipped, no SlackBuild downloaded: ${NOSB[*]}"
fi
if [ ${#HELD[@]} -gt 0 ]; then
    echo "Skipped, on hold: ${HELD[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Failed: ${FAILED[*]}"
    exit 1
fi
