# Slackware-current: Install kernel 7.2.13 next to 7.2.12

Follows `docs/README-slackware-current-kernel-update.md`. Kernel stays
blacklisted in slackpkg; use `installpkg`, never `upgradepkg`.

After this: "latest" = 7.2.13, "previous" = 7.2.12, and 7.2.11 is removed
once 7.2.13 boots fine (keep two).

## 0. Confirm the partitions

The doc says: p4 = Slackware (ext4, label `slackware-root`), p5 = NetBSD
(ufs). Check it is still true:

```sh
lsblk -f /dev/nvme0n1
su -c 'blkid /dev/nvme0n1p4 /dev/nvme0n1p5'
findmnt /
```

`findmnt /` must show `/dev/nvme0n1p4`. Note the UUID of p4 for
UUID-based entries (see step 4).

## 1. Download and verify

```sh
su -
NEW=7.2.13
MIRROR=https://mirrors.slackware.com/slackware/slackware64-current
mkdir -p /root/kernel-current && cd /root/kernel-current
wget $MIRROR/slackware64/a/kernel-generic-$NEW-x86_64-1.txz \
     $MIRROR/slackware64/a/kernel-generic-$NEW-x86_64-1.txz.asc
gpg --verify kernel-generic-$NEW-x86_64-1.txz.asc kernel-generic-$NEW-x86_64-1.txz
```

Expect `Good signature from "Slackware Linux Project ..."`. If the build
number is not `-1`, check the name in `ChangeLog.txt` / the `a/` directory.

## 2. Install next to 7.2.12 (still as root)

```sh
installpkg kernel-generic-$NEW-x86_64-1.txz
```

The package script builds `/boot/initrd-7.2.13.img`, repoints `vmlinuz`,
`vmlinuz-generic`, `initrd.gz`, `initrd-generic.img` to 7.2.13, and runs
`update-grub` (Slackware's own grub.cfg, harmless). No manual mkinitrd.

Only if the initrd is missing or broken, build it yourself:

```sh
mkinitrd -c -k 7.2.13 -f ext4 -r /dev/nvme0n1p4 -u -o /boot/initrd-7.2.13.img
```

(or `$(/usr/share/mkinitrd/mkinitrd_command_generator.sh -k 7.2.13 -r)` to
see the generated command first).

## 3. Check

```sh
ls -l /boot/vmlinuz /boot/initrd.gz /boot/vmlinuz-7.2.1* /boot/initrd-7.2.1*
ls /lib/modules
zcat /boot/initrd.gz | cpio -t 2>/dev/null | grep -m1 lib/modules/
ls /var/lib/pkgtools/packages/ | grep kernel-generic
```

Expected: `vmlinuz -> vmlinuz-7.2.13`, `initrd.gz -> initrd-7.2.13.img`,
initrd contains `lib/modules/7.2.13`, and 7.2.12 files
(`vmlinuz-7.2.12`, `initrd-7.2.12.img`, `/lib/modules/7.2.12`) still there.

## 4. Update the "previous" entry in Fedora's GRUB

The "Slackware -current" entry follows the symlinks, so it already boots
7.2.13 with no change. Only "previous" moves from 7.2.11 to 7.2.12.

Quick edit now from Slackware (lasts until Fedora regenerates grub.cfg):

```sh
su - root
mkdir -p /mnt/fedboot && mount /dev/nvme0n1p2 /mnt/fedboot
cp /mnt/fedboot/grub2/grub.cfg /mnt/fedboot/grub2/grub.cfg.bak
vim /mnt/fedboot/grub2/grub.cfg    # section "BEGIN /etc/grub.d/40_custom"
umount /mnt/fedboot
```

New "previous" entry (label search, as you have now):

```
menuentry "Slackware -current (7.2.12 previous)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz-7.2.12 root=/dev/nvme0n1p4 ro
    initrd /boot/intel-ucode.img /boot/initrd-7.2.12.img
}
```

UUID variant (survives partition renumbering; use the UUID from `blkid`):

```
    search --no-floppy --fs-uuid --set=root <UUID-of-p4>
    linux /boot/vmlinuz-7.2.12 root=UUID=<UUID-of-p4> ro
```

Do the same in the "Slackware -current" entry in case of switching to UUIDs.
Label search already works fine, so this is optional.

### Make it permanent (next time in Fedora)

```sh
ls /etc/grub.d/                         # find your 40_custom* file
sudo vim /etc/grub.d/40_custom*         # same change as above
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
grep -n 'menuentry "Slackware' /boot/grub2/grub.cfg
```

## 5. Reboot and test

Boot "Slackware -current", then:

```sh
uname -r                                # 7.2.13
su -c 'dmesg --level=err,warn'
su -c 'dmesg | grep -i microcode'
```

If it fails, boot "Slackware -current (7.2.12 previous)".

## 6. Remove 7.2.11 (keep two last)

Only after 7.2.13 works:

```sh
su -c 'removepkg kernel-generic-7.2.11-x86_64-1'
ls /boot/initrd-7.2.11* /lib/modules/    # initrd-7.2.11.gz should be gone
su -c 'rm -f /boot/initrd-7.2.11.gz'     # only if still there
```
