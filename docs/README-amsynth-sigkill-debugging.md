# amsynth 2.0.0 "Killed" on Slackware-current (PipeWire) - debugging notes

## Summary

- **Symptom:** `amsynth` 2.0.0 (built from AlienBOB's SlackBuild with `VERSION=2.0.0`)
  dies instantly. The shell prints `Killed`, there is no other output, and nothing
  appears in `dmesg`.
- **Root cause:** the login session's realtime limits were both 0:
  - RLIMIT_RTPRIO = 0 (`ulimit -r`)
  - RLIMIT_RTTIME = 0 (`ulimit -R`)

  PipeWire's `25-pw-rlimits.conf` grants realtime limits only to the `@pipewire`
  group, which does not exist on Slackware, and rtkit was not running. With an
  RTTIME hard limit of 0, the kernel SIGKILLs the JACK client's PipeWire realtime
  thread (`data-loop.0`) immediately.
- **This is not an amsynth bug.** Any JACK client under PipeWire can hit it.
- **Fix:** grant realtime limits to the `audio` group in a separate
  `/etc/security/limits.d/` file, then log out and back in.
- **Workaround** (without the fix): `audio_driver alsa` in `~/.config/amsynth/config`.
  The ALSA path does not trigger the kill.

## Environment

- Slackware-current, x86_64
- Audio stack: PipeWire, with pipewire-alsa and pipewire-jack (JACK API provided by PipeWire)
- No rtkit daemon running
- User in the `audio` group; no `pipewire` group on the system
- amsynth 2.0.0 built from http://www.slackware.com/~alien/slackbuilds (amsynth.SlackBuild)

## The fix: realtime limits via limits.d

### Diagnose

```
ulimit -r; ulimit -R                     # current shell: realtime priority / timeout
grep -i -e realtime -e rttime /proc/<pid>/limits
id                                       # group membership
grep -e pipewire -e audio /etc/group
pgrep -a rtkit
ls /etc/security/limits.d/
```

Bad state found:

```
ulimit -r -> 0
ulimit -R -> 0
/proc/<amsynth pid>/limits:
  Max realtime priority     0     0
  Max realtime timeout      0     0     us
```

**Important:** in `/proc/<pid>/limits`, no limit is shown as the word `unlimited`.
A `0` is the strictest value, not "no limit". Also, a bare `ulimit` shows only the
file-size limit (`-f`); use `ulimit -r` and `ulimit -R` for the realtime limits.

### Why PipeWire's own file did not help

`/etc/security/limits.d/25-pw-rlimits.conf` (installed by the PipeWire package):

```
@pipewire   - rtprio  95
@pipewire   - nice    -19
@pipewire   - memlock 4194304
```

- Its own comment says it is up to the distribution or user to create the
  `@pipewire` group. Slackware does not, so the rule never matches.
- It sets no `rttime`. An RTTIME hard limit of 0 cannot be raised by an
  unprivileged process, so even with a `pipewire` group, `rttime` still has to be
  set by PAM.
- PipeWire falls back to rtkit when rlimits do not allow realtime priority, and
  rtkit was not running.

### Create a new file (do not edit the package's file)

`25-pw-rlimits.conf` belongs to the PipeWire package and may be replaced on
upgrade, which would silently undo local edits. Use a separate file instead.
Reusing the existing `audio` group avoids creating a new group.

As root, `/etc/security/limits.d/95-audio-rt.conf`:

```
# Realtime limits for audio users (PipeWire/JACK clients)
@audio   -   rtprio    95
@audio   -   nice      -19
@audio   -   memlock   4194304
@audio   -   rttime    unlimited
```

- `rtprio 95`: allows SCHED_FIFO/RR up to priority 95 without rtkit (same as PipeWire's file).
- `nice -19`: allows raising thread priority (same as PipeWire's file).
- `memlock 4194304`: in KB, i.e. 4 GB; JACK clients lock audio buffers in memory.
- `rttime unlimited`: the key line; removes the RTTIME limit that caused the SIGKILL.
- `-` means both soft and hard limits.
- Files in `limits.d` are read in lexical order; `95-` sorts after `25-`.

Make sure the user is in `audio`:

```
id -nG | tr ' ' '\n' | grep -x audio || usermod -a -G audio <user>
```

Check that the login path uses pam_limits (otherwise limits.d files do nothing):

```
grep -rn pam_limits /etc/pam.d/
```

### Apply: log out and back in

PAM applies limits **only at login**. A new terminal or `su -` from an existing
session is not enough. Log out of the desktop session completely, or reboot.

### Verify

```
ulimit -r       # expect 95
ulimit -R       # expect unlimited
amsynth         # starts, default config (audio_driver auto -> JACK)
```

Result after re-login: `95` / `unlimited`, and amsynth runs with `audio_driver auto`.

## Debugging method (reusable for any "Killed" process)

### 1. Work out what kind of death it is

| Shell message         | Signal  | Typical cause                                     |
|-----------------------|---------|---------------------------------------------------|
| `Segmentation fault`  | SIGSEGV | crash, bad memory access                          |
| `Aborted`             | SIGABRT | assert / abort() / uncaught C++ exception         |
| `Illegal instruction` | SIGILL  | CPU feature mismatch (e.g. -march build)          |
| `Killed`              | SIGKILL | another process, OOM killer, or kernel rlimit     |

SIGKILL cannot be caught or traced from inside the process. The program never logs
anything, and gdb/strace only show that it died, not who killed it.

The OOM killer always writes to `dmesg`. If `dmesg | tail` shows nothing, look for a
sender process or for a kernel-side rlimit kill (RLIMIT_RTTIME, RLIMIT_CPU).

### 2. Find the sender of SIGKILL with kernel tracing (no extra tools needed)

As root:

```
mount | grep -q tracefs || mount -t tracefs nodev /sys/kernel/tracing
echo 'sig == 9' > /sys/kernel/tracing/events/signal/signal_generate/filter
echo 1 > /sys/kernel/tracing/events/signal/signal_generate/enable
cat /sys/kernel/tracing/trace_pipe
```

Start the failing program in another terminal, **as the normal user**. Then clean up:

```
echo 0 > /sys/kernel/tracing/events/signal/signal_generate/enable
echo 0 > /sys/kernel/tracing/events/signal/signal_generate/filter
```

To trace a different signal, change the filter (e.g. `sig == 11` for SIGSEGV,
`sig == 15` for SIGTERM).

#### Reading the trace line

Captured output:

```
data-loop.0-13683 [006] d..1. 22837.459317: signal_generate: sig=9 errno=0 code=128 comm=data-loop.0 pid=13683 grp=1 res=0
```

| Field                         | Meaning                                                        |
|-------------------------------|----------------------------------------------------------------|
| `data-loop.0-13683` (prefix)  | task that was running when the signal was generated (sender context) |
| `sig=9`                       | SIGKILL                                                        |
| `code=128`                    | SI_KERNEL: generated by the kernel, not by kill() from a process |
| `comm=data-loop.0 pid=13683`  | target thread                                                  |
| `grp=1`                       | sent to the whole thread group (process)                       |
| `res=0`                       | delivered                                                      |

Common `code` values:

| code | Name       | Meaning                                                |
|------|------------|--------------------------------------------------------|
| 0    | SI_USER    | kill() from a process; check the sender in the prefix  |
| -6   | SI_TKILL   | tkill()/tgkill(); often a program killing itself       |
| 128  | SI_KERNEL  | kernel-generated (rlimit exceeded, OOM, fatal fault)   |

#### Interpretation in this case

- `data-loop.0` is the realtime data thread PipeWire creates inside every client
  program (here, inside amsynth).
- A thread being killed with `SI_KERNEL` and no OOM message in dmesg points to a
  kernel rlimit, here **RLIMIT_RTTIME**.
- **Next step: check the process limits before blaming the application.** The first
  hypothesis in this session ("the audio callback spins") was wrong. The actual
  limit was 0, which kills the thread no matter how well it behaves.

### 3. strace for "what was it doing just before"

```
strace -f -o /tmp/prog.trace <program>
tail -50 /tmp/prog.trace
```

Look for `sched_setscheduler`, `setrlimit`, `kill`/`tgkill`, failing `open`/`connect`,
or a tight loop before `+++ killed by SIGKILL +++`.

**Pitfall (hit during this session):** running strace as root changed the behaviour.
Root has no PipeWire/Pulse session, so every audio backend failed ("Connection
refused", `jack_client_open() failed, status = 0x11`). amsynth showed the
audio/MIDI config dialog and exited cleanly (`exited with 0`), which looked like a
config error but wasn't one. Run desktop/audio programs as the normal user, and
use `strace` as that user too.

### 4. Isolate by switching backends / modes

```
amsynth -x                # headless, default (auto -> JACK): Killed
pw-jack amsynth           # forcing PipeWire's JACK: Killed
amsynth -x -a alsa        # headless, ALSA backend: works
```

Result: the GUI is not involved; only the JACK client path triggers the kill.

### 5. Check rlimits

```
grep -i -e realtime -e rttime /proc/<pid>/limits
ulimit -r; ulimit -R
```

`0` means "nothing allowed", not "unlimited".

## amsynth config findings

- amsynth 2.0.0 reads and writes **`~/.config/amsynth/config`**. The UI saves its
  settings there.
- `amsynth -help` still mentions `$HOME/.amSynthrc`; that is the legacy location
  from older versions and the help text is outdated.
- Format: one `key value` pair per line, `#` for comments.
- Command-line options override the config file.
- `audio_driver` choices: `auto | jack | alsa-mmap | alsa | oss`. `auto` tries JACK
  first.
- The config was never the root cause. It only selects which backend runs. With
  correct realtime limits, the default `audio_driver auto` works.

### Working config (after the limits fix)

```
audio_driver auto
alsa_audio_device default
sample_rate 48000
midi_driver auto
```

### Workaround config (if limits cannot be changed)

```
audio_driver alsa
```

or as a one-off: `amsynth -a alsa`. `alsa_audio_device default` goes through the
pipewire-alsa plugin, so sound still goes through PipeWire. Tradeoff: amsynth does
not appear as a JACK client (no JACK patchbay routing).

### Useful CLI options (2.0.0)

```
-x            headless mode
-a <driver>   audio driver (alsa/oss/auto; jack also accepted)
-m <driver>   MIDI driver
-r <int>      sample rate
-p <int>      polyphony
-n <name>     JACK client name
--jack_autoconnect[=true|false]
--ui-scale <scale>
```

## Reproducing on another Slackware / PipeWire install

1. Check `ulimit -r; ulimit -R` as the desktop user. If both are already fine
   (rtprio > 0, rttime `unlimited`), nothing needs doing.
2. Create `/etc/security/limits.d/95-audio-rt.conf` as above.
3. Make sure the user is in `audio`, and that `pam_limits` is in the PAM login stack.
4. Log out and back in; verify `95` / `unlimited`.
5. Start any JACK client (amsynth with `audio_driver auto`) and check that it stays up.

Alternative used by other distros: create a `pipewire` group and add the user to it
(`groupadd pipewire; usermod -a -G pipewire <user>`). On this system, `rttime`
would still have to be set separately, because `25-pw-rlimits.conf` does not set it.

## Slackware package management notes

- Building a newer version than the SlackBuild default:
  ```
  VERSION=2.0.0 ./amsynth.SlackBuild
  installpkg /tmp/amsynth-2.0.0-x86_64-1alien.tgz
  ```
- `removepkg <name>` is safe for shared dependencies:
  - dependencies are separate packages and are not touched;
  - files also listed by another installed package are skipped;
  - directories are removed only if empty;
  - files in home directories are never touched.
- Preview first: `removepkg --dry-run amsynth`
- Downgrade or upgrade in one step (no removepkg needed); upgradepkg replaces by
  package name:
  ```
  ./amsynth.SlackBuild          # no VERSION= -> script's default version
  upgradepkg /tmp/amsynth-<version>-x86_64-1alien.tgz
  ```
- Installed package lists live in `/var/lib/pkgtools/packages/`.

## Open question

Where the RTTIME limit of 0 came from was never identified. The kernel default is
unlimited, and nothing in `limits.conf` or `limits.d` set it. Something in the
login or session start lowered it. The `rttime unlimited` line overrides it, so
it no longer matters here.
