# Slackware 15.0: add a kernel from -current (keep the stock 15.0 kernel)

Goal: keep all Slackware 15.0 packages, install only the newer kernel (and
firmware) from slackware64-current next to the stock 5.15 kernel, and boot
either one from Fedora's GRUB.

Tested Oct 2026: Slackware 15.0 (fully patched with `slackpkg upgrade-all`)
+ kernel-generic-7.2.11 from -current.

## Machine / boot layout

- HP EliteBook 840 G6, UEFI, triple boot: Fedora 44, Slackware 15.0, NetBSD 11
- Boot manager: Fedora's GRUB (Slackware's elilo is not used)
- Slackware root: `/dev/nvme0n1p4`, ext4, label `slackware-root`, `/boot` on root fs
- Fedora `/boot` is a separate partition holding `grub2/grub.cfg`
- Entries for Slackware/NetBSD live in Fedora's `/etc/grub.d/40_custom`

## Things that changed in -current (vs 15.0)

- There is no `kernel-modules` (or `kernel-huge`) package any more: the modules
  are inside `kernel-generic`.
- Kernel image name is `vmlinuz-<VER>` (15.0 uses `vmlinuz-generic-<VER>`).
- Installing `kernel-generic` re-points `/boot/vmlinuz`, `/boot/vmlinuz-generic`,
  `/boot/config` and `/boot/System.map` to the new kernel.

## 1. Download and verify (as root, on Slackware)

```sh
MIRROR=https://mirrors.slackware.com/slackware/slackware64-current
mkdir -p /root/kernel-current && cd /root/kernel-current

# See what is available
wget -qO- $MIRROR/FILELIST.TXT | grep -E 'slackware64/a/kernel-(generic|firmware)-.*\.txz$'

# Download kernel-generic and kernel-firmware with signatures
for p in kernel-generic kernel-firmware; do
  f=$(wget -qO- $MIRROR/FILELIST.TXT | grep -oE "slackware64/a/${p}-[^ ]+\.txz$")
  wget $MIRROR/$f $MIRROR/$f.asc
done
ls -l
```

Verify each file with exact names (wildcards in `gpg --verify` do not work
reliably):

```sh
gpg --verify kernel-generic-7.2.11-x86_64-1.txz.asc kernel-generic-7.2.11-x86_64-1.txz
gpg --verify kernel-firmware-20261014_d545571-noarch-1.txz.asc kernel-firmware-20261014_d545571-noarch-1.txz
```

Expect `Good signature from "Slackware Linux Project <security@slackware.com>"`.
If `No public key`:

```sh
wget https://mirrors.slackware.com/slackware/slackware64-current/GPG-KEY
gpg --import GPG-KEY
```

Do not install `kernel-headers` (belongs to 15.0 glibc/toolchain).
`kernel-source` is only needed for out-of-tree modules.

## 2. Inspect the kernel package (optional)

```sh
tar tvf kernel-generic-7.2.11-x86_64-1.txz | grep -E ' boot/| lib/modules/7[^/]*/$'
tar tf  kernel-generic-7.2.11-x86_64-1.txz | grep -m3 '\.ko'
tar xOf kernel-generic-7.2.11-x86_64-1.txz install/doinst.sh
```

## 3. Firmware: backup, upgrade, check the old kernel still has its files

Newer firmware is normally backward compatible (drivers request versioned file
names), but old versions are occasionally pruned upstream, so check.

```sh
# Backup (restore all with: tar xf /root/firmware-15.0.tar -C /)
tar cf /root/firmware-15.0.tar -C / lib/firmware

upgradepkg kernel-firmware-20261014_d545571-noarch-1.txz

# Run while booted into the OLD kernel: are its iwlwifi/i915 files present?
OLD=$(uname -r)
for m in iwlwifi i915; do
  modinfo -k $OLD -F firmware $m | grep -E 'cc-a0|kbl|cml|whl|glk' | while read f; do
    ls /lib/firmware/$f* >/dev/null 2>&1 && echo "OK      $f" || echo "MISSING $f"
  done
done
```

At least one `iwlwifi-cc-a0-*` (AX200) must be OK. Restore a single missing file:

```sh
tar xf /root/firmware-15.0.tar -C / lib/firmware/iwlwifi-cc-a0-66.ucode
```

## 4. Install the kernel next to the old one

Use `installpkg`, NOT `upgradepkg` (upgradepkg would remove the 15.0 kernel).

```sh
installpkg kernel-generic-7.2.11-x86_64-1.txz
ls -l /boot /lib/modules
```

## 5. Initrd scheme

- `/boot/initrd.gz` = initrd for the latest kernel (`/boot/vmlinuz`)
- `/boot/initrd-generic-5.15.209.gz` = initrd for the stock 15.0 kernel

```sh
# New kernel -> default output /boot/initrd.gz
/usr/share/mkinitrd/mkinitrd_command_generator.sh -k 7.2.11
# run the printed command (keep -o /boot/initrd.gz)

# Old kernel -> versioned name
/usr/share/mkinitrd/mkinitrd_command_generator.sh -k 5.15.209
# run the printed command with: -o /boot/initrd-generic-5.15.209.gz

# Check which kernel each initrd belongs to
zcat /boot/initrd.gz | cpio -t 2>/dev/null | grep -m1 lib/modules/
zcat /boot/initrd-generic-5.15.209.gz | cpio -t 2>/dev/null | grep -m1 lib/modules/
```

If modules are compressed (`.ko.xz`/`.ko.zst`), make sure 15.0 kmod supports
it: `modprobe --version`.

## 6. GRUB entries (Fedora's GRUB)

Main entry uses the unversioned symlink + `initrd.gz`, so a kernel update needs
no GRUB change. Fallback entry is pinned to the stock 15.0 kernel.

Note: the old entry (`linux /boot/vmlinuz` with no `initrd`) only worked because
on 15.0 `/boot/vmlinuz` pointed to the huge kernel. With a generic kernel the
`initrd` line is required.

Entries (40_custom section):

```
menuentry "Slackware 15.0" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz root=/dev/nvme0n1p4 ro
    initrd /boot/initrd.gz
}

menuentry "Slackware 15.0 (5.15.209 fallback)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root slackware-root
    linux /boot/vmlinuz-generic-5.15.209 root=/dev/nvme0n1p4 ro
    initrd /boot/initrd-generic-5.15.209.gz
}

menuentry "NetBSD 11" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root 1DA5-E71D
    chainloader /EFI/NetBSD/bootx64.efi
}
```

### a) Quick edit from Slackware (takes effect on next boot)

```sh
lsblk -f                        # find Fedora's /boot partition
mkdir -p /mnt/fedboot
mount /dev/nvme0n1pY /mnt/fedboot
vim /mnt/fedboot/grub2/grub.cfg # edit the "BEGIN /etc/grub.d/40_custom" section
umount /mnt/fedboot
```

### b) Make it permanent (in Fedora)

`grub.cfg` is regenerated from `/etc/grub.d/40_custom`; without this step a
future `grub2-mkconfig` reverts the edit.

```sh
sudo vim /etc/grub.d/40_custom  # same entries as above
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Alternative: `grub2/custom.cfg` on Fedora's /boot is sourced at boot time by
41_custom and survives regeneration (no grub2-mkconfig needed). Do not define
the same entries in both places.

If entries do not show up, check which config the ESP stub loads:
`cat /boot/efi/EFI/fedora/grub.cfg`.

## 7. Keep slackpkg away from the kernel

Otherwise `slackpkg upgrade-all` "upgrades" the -current kernel back to 15.0.
Add to `/etc/slackpkg/blacklist`:

```
kernel-generic
kernel-modules
kernel-firmware
```

Trade-off: 15.0 kernel patches must then be installed by hand (see below).

## Routine: new -current kernel

```sh
NEW=7.x.y; PREV=7.2.11
# download + verify as in step 1, then:
installpkg kernel-generic-$NEW-x86_64-1.txz
/usr/share/mkinitrd/mkinitrd_command_generator.sh -k $NEW   # run it, -o /boot/initrd.gz
ls -l /boot/vmlinuz                                         # -> vmlinuz-$NEW
removepkg kernel-generic-$PREV-x86_64-1                     # full name only
```

Never `upgradepkg kernel-generic` while two kernel-generic packages are installed.

## Routine: 15.0 kernel patch (5.15.x)

```sh
installpkg kernel-generic-5.15.NEW-x86_64-1.txz kernel-modules-5.15.NEW-x86_64-1.txz
# mkinitrd for it with -o /boot/initrd-generic-5.15.NEW.gz
# installing it re-points the symlinks - point them back to the -current kernel:
ln -sf vmlinuz-$NEW /boot/vmlinuz
ln -sf vmlinuz-$NEW /boot/vmlinuz-generic
# update the fallback GRUB entry (version is pinned there), then remove the old 5.15:
ls /var/log/packages | grep kernel-
removepkg kernel-generic-5.15.OLD-x86_64-1 kernel-modules-5.15.OLD-x86_64-1
```

## After first boot: checks

```sh
uname -r
sudo dmesg --level=err,warn
dmesg | grep -i firmware
cat /sys/devices/system/cpu/vulnerabilities/mmio_stale_data
```

Known harmless messages on this laptop (HP BIOS bugs / informational):

- ACPI BIOS Error `\_SB._OSC` AE_AML_BUFFER_LIMIT
- ACPI Error `\_TZ.CHGZ._CRT` AE_AML_PACKAGE_LIMIT, `thermal: No valid trip points`
- `efi: memattr: Unexpected EFI Memory Attributes table version`
- `hpet_acpi_probe: no address or irqs in _CRS`
- `hp_wmi: query 0x4 returned error 0x5`, `WQZZ data block ... not found`,
  `hp_bioscfg ... malformed`, `hp-wmi: Failed to apply initial fan settings: -22`
- `Bluetooth: hci0: HCI LE Coded PHY feature bit is set ...`
- `skl_hda_dsp_generic ... widget card binding deferred`
- `kded5 uses wireless extensions` (only matters for Wi-Fi 7 hardware)
- `MMIO Stale Data CPU bug present and SMT on` - default mitigation active;
  full fix needs `nosmt` on the kernel line (costs multithread performance)

Result: with 7.2.11, sound works on Slackware 15.0 (it did not with 5.15).

## Rollback

- Boot the "5.15.209 fallback" entry.
- Remove the -current kernel: `removepkg kernel-generic-7.2.11-x86_64-1`
- Point symlinks back: `ln -sf vmlinuz-generic-5.15.209 /boot/vmlinuz` (and
  `vmlinuz-generic`), copy `initrd-generic-5.15.209.gz` to `initrd.gz`.
- Firmware: `tar xf /root/firmware-15.0.tar -C /` (or reinstall 15.0
  kernel-firmware with `upgradepkg`).
