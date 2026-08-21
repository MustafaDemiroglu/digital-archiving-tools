#!/bin/bash
# see library for needed parameters

#  executing python script
if ! python3 "$(dirname "${0}")"/upload_checksum_file.py "$@"; then
    echo "Failed to execute python script! please check."
    exit 6
fi