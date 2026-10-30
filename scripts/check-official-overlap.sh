#!/usr/bin/env bash
#
# List installed third-party packages (build tag ending in "alien" or "_SBo")
# that also exist in the official Slackware package list, and compare versions.
# Also checks whether the official list has a newer kernel than the newest
# installed one (kernel-* is usually blacklisted and installed side by side).
# Read-only: nothing on the system is changed.
#
# Usage: check-official-overlap.sh
# Run "slackpkg update" first so the package list is current.

PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
PKGLIST=${PKGLIST:-/var/lib/slackpkg/pkglist}
# Extended regex matched against the build field of installed packages
TAGRE=${TAGRE:-'(alien|_SBo)$'}

if [ ! -r "$PKGLIST" ]; then
    echo "Cannot read $PKGLIST (run: su -c 'slackpkg update')" >&2
    exit 1
fi
if [ ! -d "$PKGDB" ]; then
    echo "Cannot find $PKGDB" >&2
    exit 1
fi

# Returns 0 if version $1 sorts after version $2
newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

found=0
printf '%-24s %-20s %-20s %-14s %s\n' NAME INSTALLED OFFICIAL SERIES RESULT
for f in "$PKGDB"/*; do
    [ -f "$f" ] || continue
    pkg=${f##*/}
    build=${pkg##*-}
    printf '%s\n' "$build" | grep -qE "$TAGRE" || continue
    rest=${pkg%-*}          # strip build
    rest=${rest%-*}         # strip arch
    ver=${rest##*-}
    name=${rest%-*}
    # pkglist: series name version arch build fullname location ext
    while read -r series over obuild; do
        if [ "$ver" = "$over" ]; then
            result="same version (official build $obuild)"
        elif newer "$ver" "$over"; then
            result="installed is newer"
        else
            result="OFFICIAL IS NEWER"
        fi
        printf '%-24s %-20s %-20s %-14s %s\n' "$name" "$ver" "$over" "$series" "$result"
        found=$((found + 1))
    done < <(awk -v n="$name" '$2 == n { print $1, $3, $5 }' "$PKGLIST")
done

echo
echo "$found match(es) in official package list ($PKGLIST)"

# Kernel packages: several versions may be installed, compare the newest one
echo
echo "Running kernel: $(uname -r)"
printf '%-24s %-20s %-20s %-14s %s\n' NAME INSTALLED OFFICIAL SERIES RESULT
awk '$2 ~ /^kernel-/ && $2 != "kernel-firmware" { print $2, $3, $1 }' "$PKGLIST" |
while read -r name over series; do
    ver=$(for f in "$PKGDB/$name"-*; do
              [ -f "$f" ] || continue
              rest=${f##*/}
              rest=${rest%-*}; rest=${rest%-*}
              [ "${rest%-*}" = "$name" ] && echo "${rest##*-}"
          done | sort -V | tail -n1)
    [ -n "$ver" ] || continue
    if [ "$ver" = "$over" ]; then
        result="up to date"
    elif newer "$ver" "$over"; then
        result="installed is newer"
    else
        result="NEW KERNEL AVAILABLE"
    fi
    printf '%-24s %-20s %-20s %-14s %s\n' "$name" "$ver" "$over" "$series" "$result"
done
