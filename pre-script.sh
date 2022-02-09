#!/bin/sh

# Size of the /etc ramdisk in 512 bytes sectors
NANO_RAM_ETCSIZE=20480

# Size of the /tmp+/var ramdisk in 512 bytes sectors
NANO_RAM_TMPVARSIZE=20480

NANO_WORLDDIR="${WRKDIR}/world"

# Comment this out if /usr/obj is a symlink
# CPIO_SYMLINK=--insecure

# Use a custom pool name
ZFS_POOL_NAME="rpool"

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
	echo "mount -t zfs ${ZFS_POOL_NAME}/cfg" > conf/default/etc/remount

	# Put /tmp on the /var ramdisk (could be symlink already)
	_zfs_tgt_dir2symlink tmp var/tmp

	)
}

_zfs_setup_nanobsd_etc()
{
	(
	cd "${NANO_WORLDDIR}"

	# XXX Already in overlaydir/etc
	# create diskless marker file
	#touch etc/diskless

	# XXX Do not make the root filesystem R/O
	# Make root filesystem R/O by default
	#echo "root_rw_mount=NO" >> etc/defaults/rc.conf

	# XXX Already in overlaydir/etc
	# Create directory for eventual /usr/local/etc contents
	mkdir -p etc/local
	)
}

zfs_prepare()
{
	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	zroot=${ZFS_POOL_NAME}

	msg "Creating temporary ZFS pool"
	zpool create \
		-O mountpoint=/${ZFS_POOL_NAME} \
		-O canmount=noauto \
		-O checksum=sha512 \
		-O compression=on \
		-O atime=off \
		-R ${WRKDIR}/world ${zroot} /dev/${md} || exit

	if [ -n "${ORIGIN_IMAGE}" ]; then
		msg "Importing previous ZFS Datasets"
		zfs recv -F ${zroot} < "${ORIGIN_IMAGE}"
	else
		msg "Creating ZFS Datasets"
		zfs create -o mountpoint=none ${zroot}/${ZFS_BEROOT_NAME}
		zfs create -o mountpoint=/ ${zroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}
		zfs create -o mountpoint=/cfg ${zroot}/cfg
		# XXX Put /tmp on the /var ramdisk
		#zfs create -o mountpoint=/tmp -o exec=on -o setuid=off ${zroot}/tmp
		zfs create -o mountpoint=/usr -o canmount=off ${zroot}/usr
		zfs create ${zroot}/usr/home
		zfs create -o setuid=off ${zroot}/usr/ports
		zfs create ${zroot}/usr/src
		zfs create ${zroot}/usr/obj
		zfs create -o mountpoint=/var -o canmount=off ${zroot}/var
		# XXX Treat /var as monolithic
		#zfs create -o exec=off -o setuid=off ${zroot}/var/audit
		#zfs create -o exec=off -o setuid=off ${zroot}/var/crash
		#zfs create -o exec=off -o setuid=off ${zroot}/var/log
		#zfs create -o atime=on ${zroot}/var/mail
		#zfs create -o setuid=off ${zroot}/var/tmp
		#chmod 1777 ${WRKDIR}/world/tmp ${WRKDIR}/world/var/tmp
	fi
}

zfs_build()
{
	if [ -z "${ORIGIN_IMAGE}" ]; then
		if [ -n "${SWAPSIZE}" -a "${SWAPSIZE}" != "0" ]; then
			cat >> ${WRKDIR}/world/etc/fstab <<-EOSWAP
			/dev/gpt/swap0.eli	none			swap	sw,late		0	0
			EOSWAP
		fi

		# Symbolic link to /home
		ln -sf /usr/home ${WRKDIR}/world/home

		# NanoBSD-like configuration
		_zfs_setup_nanobsd_etc
		_zfs_populate_cfg
		_zfs_setup_nanobsd

		# XXX Created in overlay
		# XXX Missing empty files
		#mkdir -p ${WRKDIR}/world/etc/zfs
		#touch ${WRKDIR}/world/etc/zfs/exports
		#touch ${WRKDIR}/world/etc/opiekeys
		#chmod 0600 ${WRKDIR}/world/etc/opiekeys
	fi
}

zfs_generate()
{
	: ${SNAPSHOT_NAME:=$IMAGENAME}
	FINALIMAGE=${IMAGENAME}.img
	zroot="${ZFS_POOL_NAME}"
	zpool set bootfs=${zroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME} ${zroot}
	zpool set autoexpand=on ${zroot}
	zfs set canmount=noauto ${zroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}

	SNAPSPEC="${zroot}@${SNAPSHOT_NAME}"

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
			BESNAPSPEC="${zroot}/${ZFS_BEROOT_NAME}/${ZFS_BOOTFS_NAME}@${SNAPSHOT_NAME}"
			_zfs_writereplicationstream "${BESNAPSPEC}" "${IMAGENAME}.be.zfs"
			;;
		esac
		;;
	esac

	## When generating a disk image, we need to export the pool first.
	zpool export ${zroot}
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
