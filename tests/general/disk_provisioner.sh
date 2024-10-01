#!/bin/bash

# Environment variables
if [ -z "${PYTHON:-}" ]; then
	if type -p python3; then
		PYTHON=python3
	elif type -p python; then
		PYTHON=python
	elif type -p python2; then
		PYTHON=python2
	else
		echo ERROR: no python interpreter found
		exit 1
	fi
fi

WORK_DIR="${WORK_DIR:-/tmp/disk_provisioner}"
#FMF_DIR # directory with provision.fmf

# Parses FMF and prints out sizes of disk to be provisioned
py_parse_fmf="$(cat << 'EOF'
from __future__ import print_function, unicode_literals

import errno
import sys
import os
import yaml

fmf_dir = os.environ.get('FMF_DIR') or '.'

try:
    with open("{}/provision.fmf".format(fmf_dir)) as f:
        raw_yaml = f.read()
    fmf_tree = yaml.safe_load(raw_yaml)
except IOError as e:
    if e.errno == errno.ENOENT:
        sys.exit(0)
    raise e

try:
    drives = fmf_tree['standard-inventory-qcow2']['qemu']['drive']
except KeyError:
    drives = []

for drive in drives:
    size = int(drive.get('size', 2 * 1024 ** 3))  # default size: 2G
    print(size)
EOF
)"

setup()
{
	local disks disk file
	local -i i=0

	# Get disk sizes from provision.fmf
	#disks="$(sed -rn 's/^\s*-?\s+size:\s+(.*)/\1/p' "${FMF_DIR:-.}/provision.fmf")"
	disks="$($PYTHON -c "$py_parse_fmf")"
	# shellcheck disable=SC2181
	if [ "$?" -ne 0 ]; then
		echo "Failed to load FMF"
		return 1
	fi

	# Nothing to do
	[ -z "$disks" ] && return 0

	if ! mkdir -p "${WORK_DIR}"; then
		if [ -d "${WORK_DIR}" ]; then
			echo "Control directory already exists."
		else
			echo "Could not create control directory."
		fi
		return 1;
	fi

	# Save iSCSI target config
	if ! which targetcli; then
    	yum install targetcli -y
	fi

	targetcli / saveconfig savefile="${WORK_DIR}"/target_backup.json

	TARGETCLI_CMD="set global auto_cd_after_create=true
/loopback create
set global auto_cd_after_create=false"

	for disk in $disks ;do
		file="${WORK_DIR}/disk${i}"

		truncate -s "$disk" "$file"

		TARGETCLI_CMD="${TARGETCLI_CMD}
/backstores/fileio create disk${i} ${file}
luns/ create /backstores/fileio/disk${i}"

		((++i))
	done

	targetcli <<< "$TARGETCLI_CMD"
	return 0
}

cleanup()
{
	if [ ! -d "${WORK_DIR}" ]; then
		# Nothing to do
		return 0
	fi

	# Restore iSCSI target config
	targetcli / restoreconfig savefile="${WORK_DIR}"/target_backup.json clear_existing=true

	rm -rf "${WORK_DIR}"

	return 0
}

# main()

case $1 in
	start) setup;;
	stop) cleanup;;
	restart) cleanup; setup;;
	*)
		echo "No action given (use 'start', 'stop' or 'restart')"
		exit 2
		;;
esac
