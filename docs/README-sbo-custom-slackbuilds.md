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
path. Fix used for lmms: add the include path to `SLKCFLAGS` in the x86_64
branch of the SlackBuild (it is passed as `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS`):

```
grep -n SLKCFLAGS lmms.SlackBuild
# x86_64 line becomes:
  SLKCFLAGS="-O2 -fPIC $(pkg-config --cflags cairo)"
```

Alternative: rebuild the library without that feature (fltk: `CAIRO=0`, see its
README), so its headers don't include Cairo.

General check for any "header not found": `pkg-config --cflags <lib>` shows
the include path the build is missing.

### Function "was not declared" although the library declares it (Carla)

```
carla.cpp:136: error: 'carla_get_native_patchbay_plugin' was not declared in this scope
```

lmms 1.2.2's `plugins/carlabase/carla.h` picks Carla headers with
`#if CARLA_VERSION_HEX >= 0x010911`, but nothing includes `CarlaDefines.h`
(which defines that macro) before the check. An undefined macro is 0 in `#if`,
so it takes the "old Carla" branch and never includes `CarlaNativePlugin.h`.
Same error with Carla 2.6-alpha and 2.5.10, so the Carla version was not the cause.

How it was found: compare what the library declares with what the program includes:

```
grep -rn -E 'native_(patchbay|rack)_plugin|define CARLA_VERSION_HEX' /usr/include/carla/
grep -n -E 'include|carla_get_native|CARLA_' /tmp/SBo/lmms/plugins/carlabase/carla.h
```

Fix in `lmms.SlackBuild`, in the source dir (next to the CMake fixes):

```
# Carla: define CARLA_VERSION_HEX before carla.h checks it
sed -i 's|^#include <QtCore/QMutex>|&\n#include "CarlaDefines.h"|' plugins/carlabase/carla.h
```

Without Carla, lmms can be built with `-DWANT_CARLA=OFF` in its `cmake` options.

### Which Carla

Alien's carla SlackBuild builds a 2.6.0-alpha git snapshot. Stable 2.5.10 was
built instead (lmms 1.2.2 targets the stable API), from GitHub's tag archive,
renamed to what the SlackBuild expects:

```
cd ~/slackbuilds/carla/build
wget -O carla-2.5.10.tar.gz https://github.com/falkTX/Carla/archive/refs/tags/v2.5.10.tar.gz
cd ~
su -c './build-slackbuild.sh -q -f -i -V 2.5.10 carla'
```

`-f` is needed because the installed snapshot (`20241124_...`) sorts as newer
than `2.5.10`. MinGW-w64 and wine in its `slack-required` are optional (Windows
plugin bridge), so build without `-d`.

## Case study: lmms 1.2.2 on -current, all changes

Order: fltk 1.4.5, stk 5.0.1, (Alien) libgig, portaudio, carla 2.5.10, then lmms.

| Package | Change |
|---|---|
| fltk | `VERSION=1.4.5` (GitHub release tarball); doc globs `CHANGES* CREDITS* README*`; remove `usr/man/cat*` |
| stk | `VERSION=5.0.1` (ccrma release tarball, has `configure`); doc globs `INSTALL* README*` |
| carla | stable 2.5.10 instead of the git snapshot; no MinGW-w64/wine |
| lmms | `CMAKE_POLICY_VERSION_MINIMUM=3.5`; CMP0026/CMP0050/LOCATION sed; `$(pkg-config --cflags cairo)` in `SLKCFLAGS`; `CarlaDefines.h` include in `carla.h` |

Build command used:

```
cd ~/sbo/lmms
su -c 'NUMJOBS=-j$(nproc) CMAKE_POLICY_VERSION_MINIMUM=3.5 sh ./lmms.SlackBuild 2>&1 | tee build.log'
```

## Case study: MinGW-w64 (Alien) on -current - abandoned

MinGW-w64 (a Windows cross-compiler, GCC 13.1 + binutils 2.40) is listed as a
carla dependency, but only for the Windows plugin bridge (needs wine). Building
2023 toolchain sources with -current's GCC 16 hit one incompatibility after
another; useful as a reference for building old code with a new compiler:

| Error | Cause | Fix |
|---|---|---|
| gmp: `could not find a working compiler, long long reliability test 1` | new GCC defaults to C23 | `export CFLAGS="$SLKCFLAGS -std=gnu17"` (C only) |
| binutils: `gprofng/libcollector` errors | old gprofng vs new glibc/GCC | `--disable-gprofng` in binutils `configure` |
| `Error: unknown pseudo-op: .base64` | GCC 15+ emits `.base64`; binutils < 2.43 can't assemble it | `BINUTILS=2.45` |
| libcody: `S2C(const char8_t [2])` | new GCC defaults to C++20 (`char8_t`) | `export CXXFLAGS="$SLKCFLAGS -fno-char8_t"` |
| libcody: `C++11 is required` | `-std=gnu++17` in `CXXFLAGS` overrides the `-std=c++11` configure adds | use `-fno-char8_t`, not `-std=...`, in `CXXFLAGS` |
| `macro 'toupper' passed 2 arguments` in libstdc++ 16 headers | GCC 13's `safe-ctype.h` macros vs newer libstdc++ | stopped here (possible: `-include locale` in `CXXFLAGS`, or newer GCC) |

Lessons: put `-std=` flags in `CFLAGS` or `CXXFLAGS` only, not in a shared
`SLKCFLAGS` (it also lands in `CPPFLAGS`); check whether a "dependency" is
actually needed before building a toolchain.

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

Alien and SBo packages can be mixed (lmms from SBo uses carla, libgig and
portaudio from Alien); check dependency names, they can differ between the two.
