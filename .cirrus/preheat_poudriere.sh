#!/bin/sh

# Pre-heat Poudriere
#
# Download pre-built packages to avoid timeouts and speed up the process.

_preheat_create_packages_directory()
{
	mkdir -p /usr/local/poudriere/data/packages/router-quarterly/All
}

_preheat_fetch_packagesite()
{
	fetch http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/packagesite.txz
	tar -zxf packagesite.txz packagesite.yaml
}

_preheat_fetch_pkg()
{
	_origin="$1"

	_path="$(_preheat_origin_get_path $_origin)"
	fetch -o /usr/local/poudriere/data/packages/router-quarterly/"${_path}" http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/"${_path}"

	_path_txz="$(echo ${path%%.pkg}).txz"
	ln -s /usr/local/poudriere/data/packages/router-quarterly/"${_path}" /usr/local/poudriere/data/packages/router-quarterly/"${_path_txz}"
}

_preheat_origin_get_path()
{
	_origin="$1"

	jq --arg origin "$_origin" --arg name "${_origin##*/}" 'select(.origin == $origin) | select(.name == $name) | .path' packagesite.yaml | tr -d '"'
}

_XXX_patch_poudriere()
{
	fetch -o /usr/local/share/poudriere/image_zfs.sh https://raw.githubusercontent.com/freebsd/poudriere/master/src/share/poudriere/image_zfs.sh
}

# Pre-heat
#
_preheat_create_packages_directory
_XXX_patch_poudriere
_preheat_fetch_packagesite

## fetch pkg
_preheat_fetch_pkg "ports-mgmt/pkg"

## fetch each origin from pkglist
for _origin in $(cat $CIRRUS_WORKING_DIR/pkglist); do
	_preheat_fetch_pkg "$_origin"
done
