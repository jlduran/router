#!/bin/sh

# Size of the /etc ramdisk
NANO_RAM_ETCSIZE="32m"

# Size of the /tmp+/var ramdisk
NANO_RAM_TMPVARSIZE="32m"

NANO_WORLDDIR="${WRKDIR}/world"

# Comment this out if /usr/obj is a symlink
# CPIO_SYMLINK=--insecure

# Use a standard pool name
ZFS_POOL_NAME="zroot"
TMP_ZFS_POOL_NAME="${ZFS_POOL_NAME}.$(jot -r 1 1000000000)"

# XXX use this in the meantime efi_rng gets MFCd
make_entropy_seeds() {
	umask 077
	for i in /entropy /boot/entropy; do
		i="${NANO_WORLDDIR}/$i"
		dd if=/dev/random of="$i" bs=4096 count=1
		chown 0:0 "$i"
	done
}

# XXX override in the meantime (not yet upstreamed)
make_esp_file() {
	local file size loader stagedir fatbits efibootname
	file=$1
	size=$2
	loader=$3
	FAT16MIN=2
	FAT32MIN=33

	if [ "$size" -ge "$FAT32MIN" ]; then
		fatbits=32
	elif [ "$size" -ge "$FAT16MIN" ]; then
		fatbits=16
	else
		fatbits=12
	fi

	msg "Creating ESP image"
	stagedir=$(mktemp -d /tmp/stand-test.XXXXXX)
	mkdir -p "${stagedir}/EFI/BOOT"
	mkdir -p "${stagedir}/EFI/FreeBSD"
	efibootname=$(get_uefi_bootname)
	cp "${loader}" "${stagedir}/EFI/BOOT/${efibootname}.efi"
	cp "${loader}" "${stagedir}/EFI/FreeBSD/loader.efi"
	makefs -t msdos \
	    -o fat_type=${fatbits} \
	    -o OEM_string="" \
	    -o sectors_per_cluster=1 \
	    -o volume_label=EFISYS \
	    -s ${size}m \
	    "${file}" "${stagedir}" \
	    >/dev/null 2>&1
	rm -rf "${stagedir}"
	msg "ESP Image created"
}

_zfs_populate_cfg()
{
	if [ -d "${SAVED_PWD}/cfg" ]; then
		CFGDIR="${SAVED_PWD}/cfg"

		cp -a ${CFGDIR}/* ${NANO_WORLDDIR}/cfg
	fi
}

#
# Convert a directory into a symlink. Takes two arguments, the
# current directory and what it should become a symlink to. The
# directory is removed and a symlink is created.
#
_zfs_tgt_dir2symlink()
{
	dir=$1
	symlink=$2

	cd "${NANO_WORLDDIR}"
	rm -xrf "$dir"
	ln -s "$symlink" "$dir"
}

_zfs_setup_nanobsd()
{
	(
	cd "${NANO_WORLDDIR}"

	# Move /usr/local/etc to /etc/local so that the /cfg stuff
	# can stomp on it.  Otherwise packages like ipsec-tools which
	# have hardcoded paths under ${prefix}/etc are not tweakable.
	if [ -d usr/local/etc ] ; then
		(
		cd usr/local/etc
		find . -print | cpio ${CPIO_SYMLINK} -dumpl ../../../etc/local
		cd ..
		rm -xrf etc
		)
	fi

	# Always setup the usr/local/etc -> etc/local symlink.
	# usr/local/etc gets created by packages, but if no packages
	# are installed by this point, but are later in the process,
	# the symlink not being here causes problems. It never hurts
	# to have the symlink in error though.
	ln -s ../../etc/local usr/local/etc

	for d in var etc
	do
		# link /$d under /conf
		# we use hard links so we have them both places.
		# the files in /$d will be hidden by the mount.
		mkdir -p conf/base/$d conf/default/$d
		find $d -print | cpio ${CPIO_SYMLINK} -dumpl conf/base/
	done

	echo "$NANO_RAM_ETCSIZE" > conf/base/etc/md_size
	echo "$NANO_RAM_TMPVARSIZE" > conf/base/var/md_size

	# pick up config files from the special partition
	echo "mount -o ro -t zfs ${ZFS_POOL_NAME}/cfg" > conf/default/etc/remount

	# Put /tmp on the /var ramdisk (could be symlink already)
	_zfs_tgt_dir2symlink tmp var/tmp

	)
}

_zfs_setup_nanobsd_etc()
{
	(
	cd "${NANO_WORLDDIR}"

	# create diskless marker file
	touch etc/diskless

	# make root filesystem R/O by default
	sysrc -f etc/defaults/vendor.conf "root_rw_mount=NO"

	echo "${ZFS_POOL_NAME}/cfg		/cfg		zfs	rw,noatime,noauto	0	0" >> etc/fstab
	mkdir -p cfg

	# Create directory for eventual /usr/local/etc contents
	mkdir -p etc/local

	# Add some first boot empty files
	touch etc/opiekeys
	chmod 0600 etc/opiekeys
	touch etc/zfs/exports
	)
}

zfs_prepare()
{
	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	zroot=${ZFS_POOL_NAME}
	tmpzroot=${TMP_ZFS_POOL_NAME}

	msg "Creating temporary ZFS pool"
	zpool create \
	    -O mountpoint=/${ZFS_POOL_NAME} \
	    -O canmount=noauto \
	    -O checksum=sha512 \
	    -O compression=on \
	    -O atime=off \
	    -t ${tmpzroot} \
	    -R ${WRKDIR}/world ${zroot} /dev/${md} || exit

	if [ -n "${ORIGIN_IMAGE}" ]; then
		msg "Importing previous ZFS Datasets"
		zfs recv -F ${tmpzroot} < "${ORIGIN_IMAGE}"
	else
		msg "Creating ZFS Datasets"
		zfs create -o mountpoint=none ${tmpzroot}/${ZFS_BEROOT_NAME}
		zfs create -o mountpoint=/ ${tmpzroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}
		# XXX Put /tmp on the /var ramdisk
		#zfs create -o mountpoint=/tmp -o exec=on -o setuid=off ${tmpzroot}/tmp
		zfs create -o mountpoint=/usr -o canmount=off ${tmpzroot}/usr
		zfs create ${tmpzroot}/usr/home
		#zfs create -o setuid=off ${tmpzroot}/usr/ports
		#zfs create ${tmpzroot}/usr/src
		#zfs create ${tmpzroot}/usr/obj
		# XXX Treat /var as monolithic
		zfs create -o mountpoint=/var -o canmount=off ${tmpzroot}/var
		#zfs create -o exec=off -o setuid=off ${tmpzroot}/var/audit
		#zfs create -o exec=off -o setuid=off ${tmpzroot}/var/crash
		#zfs create -o exec=off -o setuid=off ${tmpzroot}/var/log
		#zfs create -o atime=on ${tmpzroot}/var/mail
		#zfs create -o setuid=off ${tmpzroot}/var/tmp
		#chmod 1777 ${WRKDIR}/world/tmp ${WRKDIR}/world/var/tmp

		# Create and mount /cfg so it can be populated
		zfs create -o mountpoint=legacy -o exec=off -o setuid=off ${tmpzroot}/cfg
		mkdir -p ${WRKDIR}/world/cfg
		mount -t zfs ${tmpzroot}/cfg ${WRKDIR}/world/cfg

		# Create additional datasets to be used by jails and VMs
		zfs create -o mountpoint=/usr/freebsd-dist ${tmpzroot}/usr/freebsd-dist
		zfs create -o mountpoint=/jail ${tmpzroot}/jail
		zfs create -o mountpoint=/vm ${tmpzroot}/vm
	fi
}

zfs_build()
{
	if [ -z "${ORIGIN_IMAGE}" ]; then
		cat >> ${WRKDIR}/world/etc/fstab <<-EOEFI
		# Device		Mountpoint	FStype	Options			Dump	Pass#
		/dev/gpt/efiboot0	/boot/efi	msdosfs	rw,noatime,noauto	2	2
		EOEFI
		if [ -n "${SWAPSIZE}" ] && [ "${SWAPSIZE}" != "0" ]; then
			cat >> ${WRKDIR}/world/etc/fstab <<-EOSWAP
			/dev/gpt/swap0.eli	none		swap	sw,late			0	0
			EOSWAP
		fi

		# Symbolic link to /home
		ln -sf /usr/home ${WRKDIR}/world/home

		# NanoBSD-like configuration
		_zfs_setup_nanobsd_etc
		_zfs_populate_cfg
		_zfs_setup_nanobsd
		make_entropy_seeds

		# Make sure that firstboot scripts run so growfs works.
		touch ${NANO_WORLDDIR}/firstboot
	fi
}

zfs_generate()
{
	: ${SNAPSHOT_NAME:=$IMAGENAME}
	FINALIMAGE=${IMAGENAME}.img
	zroot="${ZFS_POOL_NAME}"
	tmpzroot="${TMP_ZFS_POOL_NAME}"
	zpool set bootfs=${tmpzroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME} ${tmpzroot}
	zpool set autoexpand=on ${tmpzroot}
	zfs set canmount=noauto ${tmpzroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}

	SNAPSPEC="${tmpzroot}@${SNAPSHOT_NAME}"

	msg "Creating snapshot(s) for image generation"
	zfs snapshot -r "$SNAPSPEC"

	## If we are creating a send stream, we need to do it before we export
	## the pool. Call the function to export the replication stream(s) here.
	## We do the inner case twice so we create a +full and a +be in one run.
	case "$1" in
	send)
		FINALIMAGE=${IMAGENAME}.*.zfs
		case "${MEDIAREMAINDER}" in
		*full*|send|zfs)
			_zfs_writereplicationstream "${SNAPSPEC}" "${IMAGENAME}.full.zfs"
			;;
		esac
		case "${MEDIAREMAINDER}" in
		*be*)
			BESNAPSPEC="${tmpzroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}@${SNAPSHOT_NAME}"
			_zfs_writereplicationstream "${BESNAPSPEC}" "${IMAGENAME}.be.zfs"
			;;
		esac
		;;
	esac

	## When generating a disk image, we need to export the pool first.
	zpool export ${tmpzroot}
	zroot=
	/sbin/mdconfig -d -u ${md#md}
	md=

	case "$1" in
	raw)
		mv "${WRKDIR}/raw.img" "${OUTPUTDIR}/${FINALIMAGE}"
		;;
	gpt|zfs)
		espfilename=$(mktemp /tmp/efiboot.XXXXXX)
		zfsimage=${WRKDIR}/raw.img
		make_esp_file ${espfilename} 200 ${mnt}/boot/loader.efi

		if [ ${SWAPSIZE} != "0" ]; then
			SWAPCMD="-p freebsd-swap/swap0::${SWAPSIZE_VALUE}${SWAPSIZE_UNIT}"
			if [ $SWAPBEFORE -eq 1 ]; then
				SWAPFIRST="$SWAPCMD"
			else
				SWAPLAST="$SWAPCMD"
			fi
		fi
		mkimg -s gpt \
		    -p efi/efiboot0:=${espfilename} \
		    ${SWAPFIRST} \
		    -p freebsd-zfs/zfs0:=${zfsimage} \
		    ${SWAPLAST} \
		    -o "${OUTPUTDIR}/${FINALIMAGE}"
		rm -rf ${espfilename}
		;;
	esac
}
