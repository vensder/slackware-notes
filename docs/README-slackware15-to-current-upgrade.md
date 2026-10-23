# Slackware 15.0 -> slackware64-current: full upgrade with slackpkg

Done Oct 2026 on the HP EliteBook 840 G6, after the -current kernel was
already installed (see the kernel note next to this file).

Result:

```
PRETTY_NAME="Slackware 15.0 x86_64 (post 15.0 -current)"
VERSION_CODENAME=current
uname -r: 7.2.11
```

## Starting point

- Slackware 15.0, fully patched (`slackpkg upgrade-all`)
- Kernel 7.2.11 from -current installed with `installpkg` and running
  (`/boot/vmlinuz -> vmlinuz-7.2.11`, `/boot/initrd.gz` built for it)
- Fallback: 5.15.209 generic + `/boot/initrd-generic-5.15.209.gz`
- Boot manager: Fedora's GRUB (entries use `/boot/vmlinuz` + `/boot/initrd.gz`)

Do NOT run `grub-install`, `grub-mkconfig`, `geninitrd` or `eliloconfig` on
Slackware: Fedora's GRUB owns the boot, and its entries need no change.

Order follows -current `UPGRADE.TXT`: obsolete packages out, aaa_glibc-solibs,
then pkgtools/tar/xz/findutils/mkinitrd, then everything else, then configs.

## 0. Backup

Full backup from Fedora (Slackware root not mounted elsewhere):

```sh
sudo mkdir -p /mnt/slack && sudo mount /dev/nvme0n1p4 /mnt/slack
sudo tar --numeric-owner --xattrs -cpzf ~/slackware15-root.tar.gz -C /mnt/slack .
sudo umount /mnt/slack
```

Minimum on Slackware (as root):

```sh
tar czf /root/etc-15.0.tar.gz /etc
ls /var/lib/pkgtools/packages/ > /root/packages-15.0.txt
```

Note: `/var/log/packages` is a symlink and root's `ls` does not follow it
without a trailing slash, so use `/var/lib/pkgtools/packages/`.

Third-party packages (need rebuild; clean-system offers to remove them):

```sh
ls /var/lib/pkgtools/packages/ | grep -vE -- '-(x86_64|noarch)-[0-9]+$'
ls /var/lib/pkgtools/packages/ | grep -iE 'sbo|alien'
```

## 1. Make sure Wi-Fi survives logging out of KDE

NetworkManager runs as a system daemon, but a password stored in KWallet
needs the KDE session.

```sh
nmcli con show
nmcli -f connection.permissions,802-11-wireless-security.psk-flags con show "NAME"
```

Wanted: `connection.permissions: --` and `psk-flags: 0 (none)`. If not:

```sh
nmcli con mod "NAME" connection.permissions "" \
    802-11-wireless-security.psk-flags 0 \
    802-11-wireless-security.psk "PASSWORD"
```

## 2. slackpkg: mirror and blacklist

`/etc/slackpkg/mirrors`: comment out the 15.0 line, enable one -current line:

```
https://mirrors.slackware.com/slackware/slackware64-current/
```

`/etc/slackpkg/blacklist`:

```
kernel-generic
kernel-modules
kernel-huge
```

- `kernel-firmware` is not blacklisted; it upgrades with the system.
- `kernel-modules` / `kernel-huge` keep `clean-system` from removing the 5.15
  fallback (those packages no longer exist in -current).
- `kernel-generic` protects both kernels; new -current kernels are installed by
  hand (see kernel note).

## 3. Leave the desktop

Why: running programs keep the old (unlinked) files and keep working, but
anything started during the upgrade can load a mix of old and new libraries
(Plasma 5 -> 6, glibc, Qt, dbus). If the desktop crashes, the terminal running
slackpkg dies with it and leaves a half-upgraded system.

1. Log out of KDE.
2. Ctrl+Alt+F2, log in as root.
3. `telinit 3` (no X, network stays up; runlevel 1 would drop Wi-Fi).
4. `ping -c3 slackware.com`
5. Start `tmux` and run everything below inside it.

## 4. Refresh key and package lists

```sh
slackpkg update gpg
slackpkg update
```

Confirm the warning about a -current mirror on a 15.0 system.

## 5. Core packages first, in this order

```sh
slackpkg upgrade aaa_glibc-solibs
slackpkg upgrade pkgtools tar xz findutils mkinitrd
slackpkg upgrade slackpkg
```

## 6. Everything else

```sh
slackpkg install-new
slackpkg upgrade-all
slackpkg clean-system
```

In the `clean-system` dialog, uncheck anything to keep (SBo / third-party).

## 7. Config files

```sh
slackpkg new-config
```

What I did: chose "overwrite all" (only a few configs had local changes).
Afterwards I had to restore my own settings in:

- `/etc/inittab` (default runlevel)
- `/etc/slackpkg/mirrors` (back to the -current mirror)
- `/etc/slackpkg/blacklist` (kernel lines from step 2)

Safer alternative: choose "prompt" and merge by hand with
`vimdiff /etc/FILE /etc/FILE.new`. Never blindly overwrite `passwd`, `group`,
`shadow`, `rc.inet1.conf`, `rc.local`.

With "overwrite", slackpkg keeps each previous config as `FILE.orig` next to
the new one, so restoring local settings is just:

```sh
vimdiff /etc/inittab.orig /etc/inittab
vimdiff /etc/slackpkg/mirrors.orig /etc/slackpkg/mirrors
vimdiff /etc/slackpkg/blacklist.orig /etc/slackpkg/blacklist
```

Which old configs differ from the new ones:

```sh
find /etc -name '*.orig' | while read f; do
  cmp -s "$f" "${f%.orig}" && echo "same:    ${f%.orig}" || echo "differs: ${f%.orig}"
done
```

When done, clean up (the full old /etc is still in `/root/etc-15.0.tar.gz`):

```sh
find /etc -name '*.orig' -delete
find /etc /usr/share/vim -name '*.new'      # leftovers not merged
```

## 8. Rebuild initrd with the new -current tools

```sh
cp -a /boot/initrd.gz /boot/initrd-7.2.11.gz     # keep the pre-upgrade one
/usr/share/mkinitrd/mkinitrd_command_generator.sh -k 7.2.11
# run the printed command, keep: -o /boot/initrd.gz
zcat /boot/initrd.gz | cpio -t 2>/dev/null | grep -m3 lib/modules/7.2.11
```

Leave `/boot/initrd-generic-5.15.209.gz` alone.

## 9. Reboot and check

```sh
reboot
cat /etc/os-release              # VERSION_CODENAME=current
uname -r
sudo dmesg --level=err,warn
```

Later, in Fedora: rename the GRUB entry in `/etc/grub.d/40_custom`
(e.g. "Slackware -current") and run `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`.

## Post-upgrade fixes

### Touchpad missing in KDE settings ("no touchpad found")

Cause: the old synaptics X driver grabs the touchpad, but Plasma's touchpad
settings only work with libinput. Fix:

```sh
slackpkg remove xf86-input-synaptics
```

Touchpad settings (natural scrolling, tap-to-click) appeared in KDE settings
right after removing the package - no logout or reboot needed. `install-new` does not reinstall it; add `xf86-input-synaptics` to
the slackpkg blacklist only if it ever comes back.

### Third-party packages

Rebuild SBo and other third-party packages against -current.

## Rollback options

- If the new initrd does not boot: from the 5.15 entry (or Fedora)
  `cp /boot/initrd-7.2.11.gz /boot/initrd.gz`
- The 5.15 entry now boots the old kernel with the -current userland; usually
  works, not guaranteed.
- Real rollback: restore the full backup from step 0 (from Fedora):

```sh
sudo mount /dev/nvme0n1p4 /mnt/slack
# empty or re-mkfs the partition first (keep label slackware-root), then:
sudo tar --numeric-owner --xattrs -xpzf ~/slackware15-root.tar.gz -C /mnt/slack
```

## Routine on -current from now on

Read the ChangeLog first.

```sh
slackpkg update
slackpkg show-changelog
slackpkg install-new
slackpkg upgrade-all
slackpkg clean-system
slackpkg new-config
```

Kernel updates are manual (kernel-generic is blacklisted) - see the kernel note.

Once -current is proven, the 5.15 fallback can go:

```sh
removepkg kernel-generic-5.15.209-x86_64-1 kernel-modules-5.15.209-x86_64-1 \
          kernel-huge-5.15.209-x86_64-1
rm /boot/initrd-generic-5.15.209.gz
```

Then drop or repoint the fallback GRUB entry (e.g. to the previous -current
kernel).

## Sources

- slackware64-current `UPGRADE.TXT` (15.0 -> 16.0 HOWTO)
- https://docs.slackware.com/slackware:slackpkg
