# Slackware-current: install a new kernel, keep the previous one

For the HP EliteBook 840 G6: Slackware64-current on `/dev/nvme0n1p4` (ext4,
label `slackware-root`), booted by Fedora's GRUB. First done for
7.2.11 -> 7.2.12 (Oct 2026).

Policy: keep the latest kernel plus the previous one. GRUB has
"latest" (unversioned symlinks), "previous" (pinned) and, until it is removed,
the 5.15.209 fallback from the 15.0 days.

## Partitions

| Partition | What | Mounted in Slackware |
|---|---|---|
| nvme0n1p1 | ESP (vfat, `1DA5-E71D`) | `/boot/efi` |
| nvme0n1p2 | Fedora `/boot` (ext4) - holds `grub2/grub.cfg` | mount at `/mnt/fedboot` |
| nvme0n1p3 | Fedora root (btrfs) | - |
| nvme0n1p4 | Slackware root (ext4, `slackware-root`) | `/` |
| nvme0n1p5 | NetBSD (ufs) | - |

## Why manual

`kernel-generic` is in `/etc/slackpkg/blacklist`, so `slackpkg upgrade-all`
never touches kernels. `slackpkg search kernel` still shows an "upgrade" line
for it; that is only search output.

Never use `upgradepkg` for kernel-generic: with several kernel-generic
packages installed it can remove the ones you want to keep. Always
`installpkg` the new one and `removepkg` old ones by full name.

## What the -current kernel package does by itself

Its install script (seen with 7.2.12):

- builds `/boot/initrd-<VER>.img` with `mkinitrd_command_generator.sh`
- if `/boot/initrd.gz` was a regular file, renames it to the versioned name of
  the kernel it belonged to (here: `initrd-7.2.11.gz`), so nothing is lost
- points `/boot/initrd.gz` and `/boot/initrd-generic.img` at the new initrd
  (symlinks)
- points `/boot/vmlinuz` and `/boot/vmlinuz-generic` at `vmlinuz-<VER>`
- runs `remove-orphaned-initrds` (deletes initrds whose kernel is gone)
- runs `update-grub`, which rewrites Slackware's OWN `/boot/grub/grub.cfg`

The last one is harmless here: Fedora's GRUB is the boot manager and never
reads Slackware's `/boot/grub/grub.cfg`. Do NOT run `grub-install` on
Slackware.

So there is no manual `mkinitrd` step any more. If you ever need a custom
initrd, write it to the versioned name:

```sh
mkinitrd -c -k NEW -f ext4 -r /dev/nvme0n1p4 -u -o /boot/initrd-NEW.img
```

Notes:

- `.img` vs `.gz` is only a naming convention; both are gzip-compressed cpio
  archives and GRUB does not care. Kernels installed from now on get
  `initrd-<VER>.img`; 7.2.11 keeps its `.gz` name.
- `initrd.gz` (used by the Fedora GRUB entry) and `initrd-generic.img`
  (matches `vmlinuz-generic`, used by Slackware's own grub.cfg) both point at
  the latest initrd.
- `/boot/initrd-tree/` is only the mkinitrd build directory (left over after a
  manual `mkinitrd -c`). Safe to `rm -rf`; the package script removes it on the
  next kernel install anyway.

## 1. Download and verify

```sh
NEW=7.2.12
MIRROR=https://mirrors.slackware.com/slackware/slackware64-current
mkdir -p /root/kernel-current && cd /root/kernel-current
wget $MIRROR/slackware64/a/kernel-generic-$NEW-x86_64-1.txz \
     $MIRROR/slackware64/a/kernel-generic-$NEW-x86_64-1.txz.asc
gpg --verify kernel-generic-$NEW-x86_64-1.txz.asc kernel-generic-$NEW-x86_64-1.txz
```

Expect `Good signature from "Slackware Linux Project <security@slackware.com>"`.
The "not certified with a trusted signature" warning is normal.

## 2. Install next to the current kernel

```sh
installpkg kernel-generic-$NEW-x86_64-1.txz
```

## 3. Check

```sh
ls -l /boot/vmlinuz /boot/initrd.gz /boot/initrd-*
ls /lib/modules
zcat /boot/initrd.gz | cpio -t 2>/dev/null | grep -m1 lib/modules/
```

Expected: `vmlinuz -> vmlinuz-NEW`, `initrd.gz -> initrd-NEW.img`,
`lib/modules/NEW`, and the previous kernel's files still present.

## 4. Update Fedora's GRUB

Only the "previous" entry changes (its version is pinned). The "latest"
entry follows the symlinks and never changes.

```sh
mkdir -p /mnt/fedboot
mount /dev/nvme0n1p2 /mnt/fedboot
vim /mnt/fedboot/grub2/grub.cfg     # section "BEGIN /etc/grub.d/40_custom"
umount /mnt/fedboot
```

Entries (state after 7.2.12 install; 7.2.11's initrd has the older `.gz`
name, kernels installed from now on get `initrd-<VER>.img`):

```
menuentry "Slackware -current" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz root=/dev/nvme0n1p4 ro
    initrd /boot/intel-ucode.img /boot/initrd.gz
}

menuentry "Slackware -current (7.2.11 previous)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz-7.2.11 root=/dev/nvme0n1p4 ro
    initrd /boot/intel-ucode.img /boot/initrd-7.2.11.gz
}

menuentry "Slackware (5.15.209 fallback)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz-generic-5.15.209 root=/dev/nvme0n1p4 ro
    initrd /boot/intel-ucode.img /boot/initrd-generic-5.15.209.gz
}

menuentry "NetBSD 11" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root 1DA5-E71D
    chainloader /EFI/NetBSD/bootx64.efi
}
```

What each entry boots (validated after the 7.2.12 install):

| Entry | Kernel | Initrd |
|---|---|---|
| Slackware -current | `vmlinuz` -> `vmlinuz-7.2.12` | `initrd.gz` -> `initrd-7.2.12.img` |
| 7.2.11 previous | `vmlinuz-7.2.11` | `initrd-7.2.11.gz` (built with -current tools) |
| 5.15.209 fallback | `vmlinuz-generic-5.15.209` | `initrd-generic-5.15.209.gz` |

Notes:

- The first entry was still called "Slackware 15.0" from before the upgrade;
  rename it to "Slackware -current" since it now boots -current.
- The 5.15 fallback boots the old 15.0 kernel with the -current userland;
  usually works, not guaranteed.
- `intel-ucode.img` first on the `initrd` line loads CPU microcode before the
  initrd (optional but recommended). Check after boot:
  `dmesg | grep -i microcode`.

GRUB follows the `vmlinuz` / `initrd.gz` symlinks on ext4, so the "latest"
entry always boots whatever the package last installed.

### Make it permanent (next time in Fedora)

`grub.cfg` is regenerated from Fedora's `/etc/grub.d/40_custom`; put the same
entries there, then:

```sh
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

## 5. Reboot and test

Boot "Slackware -current", then:

```sh
uname -r
sudo dmesg --level=err,warn
```

If it fails, boot the "previous" entry.

## 6. Remove the kernel before the previous one (keep two)

Once NEW is proven, the old "previous" (PREV) gets dropped and the kernel you
were running becomes the new "previous":

```sh
ls /var/lib/pkgtools/packages/ | grep kernel-generic
removepkg kernel-generic-PREV-x86_64-1     # full name only
ls /boot/initrd-*                          # remove its initrd if still there
```

Then in step 4, change the "previous" entry to the kernel you were running
(e.g. `vmlinuz-7.2.12` + `initrd-7.2.12.img`).

Note: `remove-orphaned-initrds` runs on every kernel install, so an initrd whose
kernel has been removed is also cleaned up automatically next time.

## Removing the 5.15 fallback (when ready)

```sh
removepkg kernel-generic-5.15.209-x86_64-1 kernel-modules-5.15.209-x86_64-1 \
          kernel-huge-5.15.209-x86_64-1
rm -f /boot/initrd-generic-5.15.209.gz
```

Then delete its GRUB entry. `kernel-modules` and `kernel-huge` can then also
come out of `/etc/slackpkg/blacklist` (keep `kernel-generic`).

## Swap: zram + swapfile

### What happened

On 15.0 (kernel 5.15) I added an 8G swapfile in fstab:

```
$ ls -lah / | grep swap
-rw-------   1 root root 8.0G Oct 18 07:12 swapfile

$ grep swap /etc/fstab
/swapfile        none             swap        defaults         0   0
```

After the upgrade to -current, total swap doubled:

```
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           7.6Gi       2.6Gi       3.7Gi       467Mi       1.8Gi       5.0Gi
Swap:           15Gi          0B        15Gi

$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
zram0       251:0    0   7.6G  0 disk [SWAP]
...
```

The second swap is `zram0`, not a duplicate of the swapfile. It is not in fstab.

### What zram is

- Kernel side: the `zram` module (mainline since ~3.14, also present in
  Slackware's 5.15 kernel) creates `/dev/zram0`, a compressed block device in
  RAM. Used as swap, pages "swapped out" are compressed and kept in memory
  instead of being written to disk.
- Slackware side: -current's `/etc/rc.d/rc.S` now loads the module at boot,
  sizes the device, runs mkswap and enables it with priority 100. 15.0 did not
  do this, so zram was never visible there.

Where it is configured:

```
$ grep -rl zram /etc/rc.d /etc/default 2>/dev/null
/etc/rc.d/rc.S

$ grep -n -i zram /etc/rc.d/rc.S     # variables / config it reads
```

### Checking active swap and priorities

`swapon` is in `/sbin` (not in a normal user's PATH on Slackware):

```
$ /sbin/swapon --show
NAME       TYPE      SIZE USED PRIO
/dev/zram0 partition 7.6G   0B  100
/swapfile  file        8G   0B   -1

$ cat /proc/swaps
Filename                                Type            Size            Used            Priority
/dev/zram0                              partition       7931712         0               100
/swapfile                               file            8388604         0               -1
```

How to read it:

- Higher priority is used first: zram (100) fills before the swapfile (-1).
- 7.6G is zram's maximum UNCOMPRESSED size (= RAM size here), not memory
  reserved upfront. It uses RAM only as pages are swapped into it, typically
  compressed 2-3x.
- The swapfile is overflow when zram is full, and is what hibernation needs
  (hibernation cannot use zram).

Decision: keep both (fast compressed swap first, disk swap as overflow and for
hibernation). Good fit for an 8 GB laptop.

### If it ever needs changing

- Adjust or disable zram: see the variables in `rc.S` (`grep -n -i zram
  /etc/rc.d/rc.S`) and any config file it reads.
- Drop the swapfile instead:

```sh
swapoff /swapfile
vim /etc/fstab          # remove the /swapfile line
rm /swapfile
```

- Recreate a swapfile (reference, ext4):

```sh
dd if=/dev/zero of=/swapfile bs=1M count=8192
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
# fstab: /swapfile  none  swap  defaults  0  0
```
