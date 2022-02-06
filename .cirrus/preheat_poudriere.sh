#!/bin/sh

# Pre-heat Poudriere
#
# Download pre-built packages to avoid timeouts and speed up the process.

PREHEAT_POUDRIERE_JAILNAME="router"
PREHEAT_POUDRIERE_PTNAME="quarterly"
PREHEAT_PYTHON_SUFFIX="py38"

_XXX_patch_poudriere()
{
	fetch -o /usr/local/share/poudriere/image_zfs.sh https://raw.githubusercontent.com/freebsd/poudriere/master/src/share/poudriere/image_zfs.sh
}

_preheat_create_packages_directory()
{
	mkdir -p /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/All
}

_preheat_fetch_deps()
{
	_origin="$1"

	## fetch each origin from deps
	for _origin_dep in $(_preheat_origin_get_deps_origin "$_origin"); do
		if [ -z "$_origin_dep" ]; then
			continue
		fi

		_preheat_fetch_pkg "$_origin_dep"
		_preheat_fetch_deps "$_origin_dep"
	done
}

_preheat_fetch_packagesite()
{
	fetch http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/packagesite.txz
	tar -zxf packagesite.txz packagesite.yaml
}

_preheat_fetch_pkg()
{
	_origin="$1"

	_path="$(_preheat_origin_get_path "$_origin")"
	fetch -o /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path}" \
	    http://pkg.freebsd.org/FreeBSD:13:amd64/quarterly/"${_path}"

	_path_txz="${_path%%.pkg}.txz"
	ln -fs /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path}" \
	    /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path_txz}"
}

_preheat_origin_get_deps_origin()
{
	_origin="$1"

	_name="$(_preheat_python_suffix "$_origin")"

	jq --arg origin "$_origin" --arg name "$_name" 'select(.origin == $origin) | select(.name == $name) | .deps | .[]? | .origin' packagesite.yaml | tr -d '"'
}

_preheat_origin_get_path()
{
	_origin="$1"

	_name="$(_preheat_python_suffix "$_origin")"

	jq --arg origin "$_origin" --arg name "$_name" 'select(.origin == $origin) | select(.name == $name) | .path' packagesite.yaml | tr -d '"'
}

_preheat_python_suffix()
{
	_origin="$1"

	echo "${_origin##*/}" | sed "s/py-/${PREHEAT_PYTHON_SUFFIX}-/g"
}

# Pre-heat
#
_XXX_patch_poudriere
_preheat_create_packages_directory
_preheat_fetch_packagesite

## bootstrap pkg
## XXX pre-heat this as well
echo "ports-mgmt/pkg" > pkglist.bootstrap
poudriere bulk -j router -p quarterly -f pkglist.bootstrap

## fetch each origin from pkglist
while read -r _origin; do
	_preheat_fetch_pkg "$_origin"
	_preheat_fetch_deps "$_origin"
done < ${CIRRUS_WORKING_DIR}/pkglist
