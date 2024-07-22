#!/bin/sh

ZROOT="zroot"

CFG_FILES="rc.conf ssh hosts group hostid master.passwd passwd pwd.db spwd.db"
CFG_LOCAL_FILES=""

# Remove unused datasets
remove_unused_datasets()
{
	zfs destroy -f ${ZROOT}/tmp # XXX cannot unmount: pool or dataset is busy
	zfs destroy ${ZROOT}/usr/ports
	zfs destroy ${ZROOT}/usr/src
	zfs destroy ${ZROOT}/usr/obj # XXX dataset does not exist

	mkdir /usr/ports
	mkdir /usr/src

	# Treat /var as monolithic
	zfs destroy ${ZROOT}/var/audit
	zfs destroy ${ZROOT}/var/crash
	zfs destroy -f ${ZROOT}/var/log # XXX cannot unmount: pool or dataset is busy
	zfs destroy ${ZROOT}/var/mail
	zfs destroy ${ZROOT}/var/tmp

	mkdir /var/audit
	mkdir /var/crash
	mkdir /var/mail
	mkdir /var/tmp
}

# Create and mount /cfg so it can be populated
create_cfg_dataset()
{
	zfs create -o mountpoint=legacy -o exec=off -o setuid=off ${ZROOT}/cfg
	mkdir /cfg
	mount -t zfs ${ZROOT}/cfg /cfg
}

# Create additional datasets to be used by jails and VMs
create_additional_datasets()
{
	zfs create -o mountpoint=/usr/freebsd-dist ${ZROOT}/usr/freebsd-dist
	zfs create -o mountpoint=/jail ${ZROOT}/jail
	zfs create -o mountpoint=/vm ${ZROOT}/vm
}

# Scavenge /etc
copy_etc_cfg_files()
{
	src="$1"
	src_dirname="$(dirname "$src")"
	if [ "$src_dirname" = "." ]; then
		cp -a "/etc/${src}" /cfg
	else
		mkdir -p /cfg/"$src_dirname"
		cp -a "/etc/${src}" /cfg/"${src}"
	fi
}

# Scavenge /usr/local/etc
copy_usr_local_etc_cfg_local_files()
{
	src="$1"
	src_dirname="$(dirname "$src")"
	if [ "$src_dirname" = "." ]; then
		cp -a "/usr/local/etc/${src}" /cfg/local
	else
		mkdir -p /cfg/local/"$src_dirname"
		cp -a "/usr/local/etc/${src}" /cfg/local/"${src}"
	fi
}

remove_unused_datasets
create_cfg_dataset
create_additional_datasets

for file in $CFG_FILES; do
	copy_etc_cfg_files "$file"
done

if [ -n "$CFG_LOCAL_FILES" ]; then
	mkdir /cfg/local
	for file in $CFG_LOCAL_FILES; do
		copy_usr_local_etc_cfg_local_files "$file"
	done
fi
