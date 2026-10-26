# Building SlackBuilds.org packages on Slackware-current (manual, with version bumps)

How to build packages from <https://slackbuilds.org> (SBo) by hand on
Slackware-current, including newer versions than SBo ships, and the fixes that
were needed. Worked example: lmms 1.2.2 with its dependencies fltk and stk.

For Alien's SlackBuilds, see `README-alien-slackbuilds-scripts.md`; the
differences are summarised at the end.

## How SBo is organised

Each package is a tarball `<name>.tar.gz` with a directory `<name>/` containing:

| File | Purpose |
|---|---|
| `<name>.SlackBuild` | Build script, run as root |
| `<name>.info` | Version, source URL, MD5 sum, dependencies (shell variables) |
| `README` | Description, optional deps, build options (env vars) |
| `slack-desc` | Package description |
| `doinst.sh` | Post-install script (optional) |

Key points:

- **The SlackBuild never downloads the source.** Fetch it yourself from
  `DOWNLOAD` in the `.info` and put it next to the SlackBuild.
- SBo targets **Slackware 15.0**, not -current. Most SlackBuilds still work on
  -current, but older software may need fixes for newer GCC/Qt/CMake.
- Packages get the build tag `_SBo` (e.g. `fltk-1.4.5-x86_64-2_SBo.tgz`),
  written to `/tmp`. Build dirs are under `/tmp/SBo/`.
- Dependencies (`REQUIRES` in `.info`) are not handled automatically: build and
  install them first, in order.

## Basic procedure

```
mkdir -p ~/sbo && cd ~/sbo

# 1. get the SlackBuild(s): <category>/<name> from the package page URL
for p in libraries/fltk libraries/stk audio/lmms; do
    wget "https://slackbuilds.org/slackbuilds/15.0/$p.tar.gz"
    tar xf "${p#*/}.tar.gz"
done

# 2. per package: read, download, verify
cd ~/sbo/fltk
cat README
. ./fltk.info                    # sets VERSION, DOWNLOAD, MD5SUM, REQUIRES
echo "$VERSION | requires: $REQUIRES"
wget $DOWNLOAD
echo "$MD5SUM  ${DOWNLOAD##*/}" | md5sum -c

# 3. build and install (as root)
su -c 'sh ./fltk.SlackBuild 2>&1 | tee build.log'
su -c 'installpkg /tmp/fltk-*_SBo.t?z'
```

If `.info` has a non-empty `DOWNLOAD_x86_64` (not `UNSUPPORTED`), use that and
`MD5SUM_x86_64` instead.

Check what is already installed first (Slackware-current ships more than 15.0):

```
ls /var/lib/pkgtools/packages | grep -E '^(fltk|stk)-'
```

## Building a newer version than SBo

Most SlackBuilds take the version from the environment:
`VERSION=${VERSION:-1.3.8}`. So:

```
su -c 'VERSION=1.4.5 sh ./fltk.SlackBuild 2>&1 | tee build.log'
```

Before that:

1. **Check the SlackBuild** for anything tied to the old version:

   ```
   grep -nE 'VERSION=|configure|cmake|patch|tar x|cd \$PRGNAM|DOCS|README' fltk.SlackBuild
   ```

   - The tarball name must match what `tar x` expects
     (e.g. `$PRGNAM-$VERSION-source.tar.gz`).
   - `sed` "patches" are harmless if the text is gone (sed just changes nothing);
     real `patch` files may fail on a new version.
   - The build system must still be the same (e.g. `./configure` vs CMake).
2. **Get the source.** Projects move downloads: fltk moved to GitHub releases,
   stk's release tarball is still on its own site. Prefer the project's
   **release tarball** over GitHub's auto-generated "Source code" archive: the
   release tarball often contains the generated `configure` script, the archive
   does not.
3. **Verify it.** The `.info` MD5 is only for the old version. Use the checksum
   from the project's download page if there is one, otherwise at least test the
   archive: `tar tzf <file> > /dev/null` (or `gzip -t`, `xz -t`).
4. **Check compatibility with what depends on it.** A library update can break a
   program written for the older API (e.g. fltk 1.4 is "mostly API compatible"
   with 1.3 but not ABI compatible, so dependents must be rebuilt).
5. **Check the package before installing**, especially after a version bump:

   ```
   tar tf /tmp/stk-5.0.1-*_SBo.t?z | grep -E 'lib64/libstk|include/stk/Stk\.h|share/stk/'
   ```

## Common fixes

### Doc files renamed (`cp: cannot stat 'README'`)

The build succeeds but the doc copy at the end fails, because newer releases
renamed `README` to `README.md`/`README.txt` etc. Turn the names into globs so
they match both old and new names (example: fltk line with `DOCFILES=`):

```
grep -n -E 'CHANGES|README|INSTALL' fltk.SlackBuild
sed -i '/CHANGES/s/\bCHANGES\b/CHANGES*/; /CREDITS/s/\bCREDITS\b/CREDITS*/; /CHANGES/s/\bREADME\b/README*/' fltk.SlackBuild
```

This only works when the list is used unquoted (`cp -a $DOCFILES ...` or
literal names in the `cp` line), so the shell expands the globs. Find the new
names in the unpacked source: `su -c 'ls /tmp/SBo/<name>-<version>'`.

### Extra preformatted man pages (`usr/man/cat1`)

fltk 1.4 installs `cat1`/`cat3` copies besides `man1`/`man3`. Optional cleanup,
before the `gzip` line:

```
sed -i 's|^gzip -9 \$PKG/usr/man/man\*/\*|rm -rf $PKG/usr/man/cat*\n&|' fltk.SlackBuild
```

### CMake 4: "Compatibility with CMake < 3.5 has been removed"

Old projects declare `cmake_minimum_required` below 3.5. CMake reads this from
the environment, so no edit is needed; it also covers bundled subprojects:

```
su -c 'CMAKE_POLICY_VERSION_MINIMUM=3.5 sh ./lmms.SlackBuild 2>&1 | tee build.log'
```

### CMake 4: "Policy CMP0026/CMP0050 may not be set to OLD"

The project explicitly requests removed old behaviour; the env var above does
not help. Patch `CMakeLists.txt` from the SlackBuild, right after the
`cd $PRGNAM...` line that follows `tar x` (the source is unpacked fresh on every
run). For lmms 1.2.2 (same fix as nixpkgs):

```
# CMake 4 fixes (from nixpkgs): drop removed OLD policies, LOCATION property
sed -i -e 's/CMP0026 OLD/CMP0026 NEW/' \
       -e 's/CMP0050 OLD/CMP0050 NEW/' \
       -e 's/GET_TARGET_PROPERTY(BIN2RES bin2res LOCATION)/SET(BIN2RES $<TARGET_FILE:bin2res>)/' \
       CMakeLists.txt
```

Generic pattern: `GET_TARGET_PROPERTY(VAR target LOCATION)` becomes
`SET(VAR $<TARGET_FILE:target>)`. Check the patterns match first:
`grep -n -E 'CMP0026|CMP0050|LOCATION' /tmp/SBo/<src>/CMakeLists.txt`.

### Header not found although the library is installed (`cairo.h`)

`fatal error: cairo.h: No such file or directory` while compiling lmms's bundled
ZynAddSubFX: fltk 1.4 was built with Cairo, so its headers include `<cairo.h>`,
which lives in `/usr/include/cairo/`, but the dependent build doesn't add that
path. Either:

- add the flags to the dependent build: `$(pkg-config --cflags cairo)` in the
  C++ flags its SlackBuild passes (find them with `grep -n SLKCFLAGS <name>.SlackBuild`), or
- rebuild the library without that feature (fltk: `CAIRO=0`, see its README).

General check for any "header not found": `pkg-config --cflags <lib>` shows
the include path the build is missing.

## Finding the first error

The last lines of a failed build are usually just `make` giving up. Look for the
first real error:

```
grep -n -m5 -E 'error:|Error [0-9]|CMake Error' build.log
grep -n -A8 'CMake Error' build.log       # CMake errors with context
```

CMake prints its configuration summary even when configuring failed; the actual
error is above the summary.

## Housekeeping

- Add `_SBo` packages to `/etc/slackpkg/blacklist` (next to Alien's), so
  slackpkg doesn't remove or replace them:

  ```
  [0-9]+alien
  [0-9]+_SBo
  ```

- List SBo packages: `ls /var/lib/pkgtools/packages | grep '_SBo$'`
- Keep notes on what was changed in a SlackBuild (or keep the edited
  SlackBuild in this repo), since re-downloading the tarball overwrites it.

## SBo vs Alien's SlackBuilds

| | Alien | SBo |
|---|---|---|
| Target | Slackware-current (and 15.0) | Slackware 15.0 |
| Source download | SlackBuild downloads from `SRCURL` | Manual, URL in `.info` |
| Checksum | none | `MD5SUM` in `.info` |
| Dependencies | `slack-required` | `REQUIRES` in `.info` |
| Package tag | `alien` (e.g. `1alien`) | `_SBo` (e.g. `1_SBo`) |
| Output | `/tmp`, build in `/tmp/build` | `/tmp`, build in `/tmp/SBo` |
| Helper scripts | `download-slackbuilds.sh`, `build-slackbuild.sh` | none yet (manual) |
