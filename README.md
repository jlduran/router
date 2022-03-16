# Router

FreeBSD-based router, built using poudriere.

Largely inspired by [NanoBSD], [ZFS Magic Upgrades], and the [BSD Router Project].

## Create a new router image

1. Create a poudriere jail

       poudriere jail -c -j router -v 13.0-RELEASE

2. Create a ports tree

       poudriere ports -c -U https://git.freebsd.org/ports.git -B <quarterly branch> -p quarterly

3. Create/modify the list of ports to be included

       cat > pkglist <<EOF
       net/bird2
       sysutils/tmux
       security/strongswan
       ...
       EOF

4. Build the ports

       poudriere bulk -j router -p quarterly -f pkglist

5. Create the router image

       poudriere image -t zfs -j router -s 4g -p quarterly -h router.home -n router -f pkglist -c overlaydir -B pre-script.sh -b -w 2g

6. Test the image

       sh /usr/share/examples/bhyve/vmrun.sh -uE -m 1G -n e1000 -t tap0 -t tap1 -d /usr/local/poudriere/data/images/router.img router

## Upgrade a router image (new boot environment)

1. Update the poudriere jail

       poudriere jail -u -j router

2. Update the ports tree

       poudriere ports -u -p quarterly

   or create an updated ports tree

       poudriere ports -c -U https://git.freebsd.org/ports.git -B <new quarterly branch> -p quarterly

4. Build the ports

       poudriere bulk -j router -p quarterly -f pkglist

5. Create a router boot environment (BE)

       poudriere image -t zfs+send+be -j router -s 4g -p quarterly -h router.home -n router -f pkglist -c overlaydir -B pre-script.sh -b -w 2g

6. Test the BE image:

   1. Optionally, compress the BE image created in the previous step

          xz -9 --keep /usr/local/poudriere/data/images/router.be.zfs

   2. Start a VM with the old image

          sh /usr/share/examples/bhyve/vmrun.sh -uE -m 1G -n e1000 -t tap0 -t tap1 -d /usr/local/poudriere/data/images/router.img router

   3. From the router, import the new BE

          fetch -o - https://srv/router.be.zfs.xz | unxz | bectl import newbe

      > TODO: When testing, upgrading from 11.4 to 13.0, an upgrade to the ESP was required, it should also include an upgrade to `/boot/efi`.

   4. Boot once

          bectl activate -t newbe

   5. Reboot

          shutdown -r now "Rebooting for a firmware upgrade"

## Configuration changes

The router uses ZFS as the underlying file system, but mounts `/etc` and `/var` as memory disks (like NanoBSD).

In order to save configuration changes, issue the following command:

    # save_cfg

Configuration changes are then saved to `/cfg`, to overlay the base `/etc` template (NanoBSD-style).

## To do

- [ ] Add a `VARIANT` and a `VARIANT_ID` to /var/run/os-release
- [ ] No-priv build
- [ ] /boot/efi capsule upgrades
- [ ] Document incremental snapshots (BE)

[BSD Router Project]: https://bsdrp.net/
[NanoBSD]: https://papers.freebsd.org/2005/phk-nanobsd/
[ZFS Magic Upgrades]: https://papers.freebsd.org/2019/fosdem/jude-zfs_upgrades/
