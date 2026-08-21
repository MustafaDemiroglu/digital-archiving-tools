#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}

#  executing python script
if ! python3 "$(dirname "${0}")"/checksum_check.py "$@"; then
    echo "Failed to execute python script! please check."
    exit 6
fi