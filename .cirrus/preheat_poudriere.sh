#!/bin/sh

# Preheat Poudriere:
#
# Download built packages to avoid timeouts.

fetch http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/packagesite.txz
tar -zxf packagesite.txz

mkdir -p /usr/local/poudriere/data/packages/router-quarterly/All

for pkg in $(cat $CIRRUS_WORKING_DIR/pkglist); do
	path=$(jq --arg origin "$pkg" --arg name "${pkg##*/}" 'select(.origin == $origin) | select(.name == $name) | .path' packagesite.yaml | tr -d '"')

	# fetch .pkg
	fetch -o /usr/local/poudriere/data/packages/router-quarterly/"$(echo $path)" http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/"$(echo $path)"
	path_txz="$(echo ${path%%.pkg}).txz"
	ln -s /usr/local/poudriere/data/packages/router-quarterly/"$(echo $path)" /usr/local/poudriere/data/packages/router-quarterly/"$(echo $path_txz)"
done

#pkg fetch -dy $(cat $CIRRUS_WORKING_DIR/pkglist)
#cp /var/cache/pkg/* /usr/local/poudriere/data/packages/router-quarterly/All

# XXX Patch poudriere
fetch -o /usr/local/share/poudriere/image_zfs.sh https://raw.githubusercontent.com/freebsd/poudriere/master/src/share/poudriere/image_zfs.sh
