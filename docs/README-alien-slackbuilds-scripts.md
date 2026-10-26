# Downloading and building Alien's SlackBuilds with helper scripts

Two scripts in `scripts/` for installing packages that are missing on
Slackware-current, using SlackBuilds from
<http://www.slackware.com/~alien/slackbuilds/>:

- `download-slackbuilds.sh` - download a SlackBuild and, recursively, its dependencies
- `build-slackbuild.sh` - check versions, build, and optionally install a package and its dependencies

> **Note:** the scripts may be updated without this doc being updated.
> Check the header and `usage()` of each script (or run `build-slackbuild.sh -h`)
> for the current options and behaviour.

## Layout

Both scripts use `~/slackbuilds` by default, wherever they are run from:

```
~/slackbuilds/<package>/build/<package>.SlackBuild
                              slack-desc
                              slack-required   # dependencies, one per line
                              <sources>
```

Override the location with `SBDIR=/path/to/slackbuilds` (set the same value for
both scripts). When `build-slackbuild.sh` runs as root via `su`/`sudo`, it uses the
real user's home (from `logname` / `$SUDO_USER`), not `/root`.

## download-slackbuilds.sh

```
./download-slackbuilds.sh http://www.slackware.com/~alien/slackbuilds/vmpk/build/
```

Mirrors the `build/` dir with `wget` into `$SBDIR/<package>/build/` (no
`index.html` files, only newer files are fetched again), then reads
`slack-required` and downloads each dependency's `build/` dir the same way.

Source archives (`*.tar.*`, `*.tgz`, `*.zip`, ...) are not downloaded at this
stage; the SlackBuild downloads the version it builds from its `SRCURL`.
Compressed patches (`*.diff.gz` etc.) are still downloaded.

Speed notes:

- Apache's column-sort links (`?C=N;O=D` etc.) are skipped with `--reject-regex`;
  otherwise wget fetches 8 extra pages per directory.
- slackware.com delays requests with the default `Wget/...` user agent by ~8-10s
  per request, so the script sends a descriptive one
  (`download-slackbuilds.sh (Slackware user)`), which is not delayed.
- To check response times: `curl -o /dev/null -s -w '%{time_starttransfer}s\n' <url>`

## build-slackbuild.sh

```
build-slackbuild.sh [-cdfinqv] [-V version] <package>
build-slackbuild.sh -a [-cdfinqv]
```

| Option | Meaning |
|---|---|
| `-a` | All installed packages with build tag `alien` (instead of `<package>`), with a summary at the end. Tag can be changed with `PKGTAG=...` |
| `-c` | Check only: show SlackBuild, installed and upstream versions. No root needed |
| `-d` | Also process dependencies from `slack-required`, recursively |
| `-f` | Rebuild `<package>` even if this version is already installed |
| `-i` | Install/upgrade `<package>` after the build (`upgradepkg --install-new`) |
| `-n` | Build the newest upstream version instead of the SlackBuild default |
| `-q` | Quiet: SlackBuild output goes to `$OUTPUT/build-<pkg>-<version>.log`; last 30 lines shown on failure |
| `-v` | Verbose: show URLs requested by the upstream version check |
| `-V` | Build this exact version of `<package>` |

### How it works

1. Reads `PRGNAM`, the default `VERSION` and `SRCURL` from the SlackBuild,
   and the installed version from `/var/lib/pkgtools/packages`.
2. With `-c` or `-n`, finds the newest stable upstream version:
   - GitHub (`github.com`, `codeload.github.com`): latest published release
   - SourceForge: the project's files RSS feed
   - other sites: the directory listing of the tarball's folder
   - fallback: <https://repology.org> (newest version packaged by any distro)

   Each request has a 15s timeout and one retry, so a dead site costs ~30s at most.
3. Skips the package if the installed version is the same or newer (no downgrades).
4. With `-d`, handles dependencies first. Missing or outdated ones are built and
   **always installed**, because the parent build needs them. Installed packages
   without a downloaded SlackBuild (e.g. stock Slackware packages) are skipped.
   It stops on the first missing SlackBuild or failed build.
5. Builds with the SlackBuild itself: `VERSION=<version> bash ./<package>.SlackBuild`.
   The SlackBuild downloads the source if it isn't in the build dir yet.
6. Finds the package in `$OUTPUT` (default `/tmp`). With `-i` it installs it;
   otherwise it prints the `upgradepkg` command.

### Examples

```
# what would change, for the package and all its dependencies
./build-slackbuild.sh -c -d x42-plugins

# SlackBuild default versions, with dependencies, and install
su -c './build-slackbuild.sh -d -i x42-plugins'

# newest upstream versions of everything, and install
su -c './build-slackbuild.sh -d -n -i x42-plugins'

# specific version (e.g. when upstream can't be detected)
su -c './build-slackbuild.sh -i -V 0.9.2 vmpk'

# check all installed alien packages for newer upstream versions
./build-slackbuild.sh -a -c

# upgrade all of them to the newest upstream versions, quietly
su -c './build-slackbuild.sh -a -n -i -q'
```

`-a` without `-n` builds nothing: the SlackBuild default version is never newer
than what was installed from it.

With `su -c` the script path is relative to the current directory; give the full
path if needed, e.g. `su -c '~vensder/git/slackware-notes/scripts/build-slackbuild.sh -c vmpk'`.

### Parallel builds (`-j`)

Most Alien SlackBuilds set `NUMJOBS` themselves. Some don't (e.g. x42-plugins
prints `NUMJOBS: unbound variable` and builds with a single job). Pass it in:

```
su -c 'NUMJOBS=-j$(nproc) ./build-slackbuild.sh -n -i x42-plugins'
```

### Less build output (`MAKEFLAGS=-s`)

GNU make reads `MAKEFLAGS` from the environment; `-s` stops it echoing each
command (sub-makes inherit it). Warnings and errors are still shown.

```
su -c 'MAKEFLAGS=-s ./build-slackbuild.sh -n -i lsp-plugins'
```

Big effect on plain Makefiles (lsp-plugins, x42-plugins), small on autotools
(already quiet by default), none on Meson/CMake with Ninja. If a build fails,
rerun without it to see the failing command.

### Notes

- `-d -n` can update a library to a version its dependents don't support yet.
  If a build breaks, use `-d` alone to stay with Alien's tested versions.
- If the source download fails, see
  [Source download fails (outdated SRCURL)](#source-download-fails-outdated-srcurl).
- Older SlackBuilds may ask about symlinks in `makepkg`; answer `y`.
  With `-q` the question goes to the log, so the build looks stuck: check with
  `tail -f <log>`, then type `y` and Enter in the build terminal.
- If a build is interrupted during the source download, delete the partial
  tarball from the build dir; otherwise the SlackBuild treats it as present.
- To trace the script itself: `su -c 'bash -x ./build-slackbuild.sh ...'`.

### Source download fails (outdated SRCURL)

The SlackBuild downloads the source from its own hard-coded `SRCURL`, which the
script can't override. With `-n`/`-V` the URL is built for a version the
SlackBuild author never tested, and upstream may have moved its files since.

Example: qmmp moved releases into `<major>.<minor>/` subfolders:

```
SlackBuild URL:  http://qmmp.ylsoftware.com/files/qmmp-2.4.2.tar.bz2        (404)
Actual URL:      http://qmmp.ylsoftware.com/files/qmmp/2.4/qmmp-2.4.2.tar.bz2
```

1. See the URL the SlackBuild uses:

   ```
   grep '^SRCURL' ~/slackbuilds/qmmp/build/qmmp.SlackBuild
   ```

2. Find the real location on the project's download page (the homepage is in
   `slack-desc`), or check a temporary failure first: try `https://` instead of
   `http://`, or retry later.

3. One-off fix: download the tarball into the build dir and build that version.
   The SlackBuild uses an existing tarball and skips its own download.
   Dependencies are already installed by the failed run, so `-d` isn't needed.

   ```
   cd ~/slackbuilds/qmmp/build
   rm -f qmmp-2.4.2.tar.bz2.FAIL     # left by the failed download
   wget http://qmmp.ylsoftware.com/files/qmmp/2.4/qmmp-2.4.2.tar.bz2
   cd ~
   su -c './build-slackbuild.sh -i -V 2.4.2 qmmp'
   ```

4. Permanent fix (so later `-n` upgrades work): update `SRCURL` in the local
   SlackBuild. Bash parameter expansion helps when the path contains part of
   the version, e.g. `${VERSION%.*}` turns `2.4.2` into `2.4`:

   ```
   sed -i 's|^SRCURL=.*|SRCURL="http://qmmp.ylsoftware.com/files/qmmp/${VERSION%.*}/${PRGNAM}-${VERSION}.tar.bz2"|' \
       ~/slackbuilds/qmmp/build/qmmp.SlackBuild
   ```

   `download-slackbuilds.sh` (`wget -N`) keeps the local edit while it is newer
   than the server's file, but replaces it when Alien updates the SlackBuild,
   which may already include the fix. Worth telling Alien about the new URL.

Other useful expansions: `${VERSION%%.*}` (major only: `2`),
`${VERSION//./_}` (dots to underscores: `2_4_2`).

## Managing the installed packages

Slackware has no dependency-tracking package manager. The package database is
the files in `/var/lib/pkgtools/packages` (`/var/log/packages` is a symlink),
one per installed package, listing everything it installed. Alien's packages are
marked by the build tag `alien` at the end of the name (e.g. `vmpk-0.9.2-x86_64-1alien`).

Tools:

- **pkgtools** (built in): `installpkg`, `upgradepkg --install-new`, `removepkg`.
  Enough for packages built with these scripts.
- **slackpkg** (official): official packages only.
- **slackpkg+** (community add-on): adds third-party binary repos to slackpkg,
  including Alien's prebuilt packages for -current (his tested versions, not
  the newest upstream).
- **slpkg**, **sbopkg**: mostly for SlackBuilds.org, a separate collection aimed
  at stable releases.

### Protect them from slackpkg

Add to `/etc/slackpkg/blacklist`:

```
[0-9]+alien
```

Otherwise `slackpkg clean-system` offers to remove them as "not official", and
`slackpkg upgrade-all` could replace one if Slackware ships a package with the
same name.

### List, check for updates, remove

```
# list (match the build tag at the end, not just "alien" anywhere)
ls /var/lib/pkgtools/packages | grep 'alien$'

# names only (strip version, arch and build fields)
ls /var/lib/pkgtools/packages | grep 'alien$' | rev | cut -d- -f4- | rev

# check all for newer upstream versions (same as: build-slackbuild.sh -a -c)
for p in $(ls /var/lib/pkgtools/packages | grep 'alien$' | rev | cut -d- -f4- | rev); do
    ./build-slackbuild.sh -c "$p"
done

# remove one
su -c 'removepkg vmpk'
```

Nothing tracks reverse dependencies: before removing a package, check it isn't
needed by another one:

```
grep -lE '^vmpk( |$)' ~/slackbuilds/*/build/slack-required
```
