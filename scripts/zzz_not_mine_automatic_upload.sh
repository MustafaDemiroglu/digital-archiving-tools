#!/bin/bash                                                                                                                                                                                    
                                                                                                                                                                                               
#REQUIERMENTS                                                                                                                                                                                  
#JQ (apt install jq)                                                                                                                                                                           
                                                                                                                                                                                               
# import common conf file                                                                                                                                                                      
. /etc/hla/common.conf                                                                                                                                                                         
                                                                                                                                                                                               
# get exclusive lock or exit                                                                                                                                                                   
exlock_now || exit 1                                                                                                                                                                           
                                                                                                                                                                                               
# define default base path                                                                                                                                                                     
default_base_path="/media"                                                                                                                                                                     
                                                                                                                                                                                               
# change directory to current default base path or exit with error                                                                                                                             
cd "${default_base_path}" || exit 1                                                                                                                                                            
                                                                                                                                                                                               
# define prefix for hdd (this script was primary maked for sifi)                                                                                                                               
prefix_hdd="sifi"                                                                                                                                                                              
                                                                                                                                                                                               
# check if an input parameter was omitted and if so use this as hdd folder parameter and set default base path to nothing                                                                      
if [[ "${1}" != "" ]] && [[ -d "${1}" ]]; then                                                                                                                                                 
    sifi_list="${1}"                                                                                                                                                                           
    default_base_path=""                                                                                                                                                                       
else                                                                                                                                                                                           
    #find all SifiTransportDisks                                                                                                                                                               
    sifi_list=$(find gerlings/ krasser/ reichert/ hladigiworker/ -mindepth 1 -maxdepth 1 -type d -iname "${prefix_hdd}*")                                                                      
                                                                                                                                                                                               
    #check if list is empty and if so get all not mountet but connected drives with a ntfs filesystem                                                                                          
    if [[ "${sifi_list}" == "" ]]; then                                                                                                                                                        
        not_mountet=$(lsblk -f -o NAME,FSTYPE,MOUNTPOINT --json | jq -r '.[][]|select(.name | startswith("sd")).children[]|select(.fstype == "ntfs")|select(.mountpoint==null).name')          
    fi                                                                                                                                                                                         
                                                                                                                                                                                               
    #check if both (list of mounted and not mounted disks) lists are empty and if so exit with status 0 (nothing to do)                                                                        
    if [[ "${sifi_list}" == "" ]] && [[ "${not_mountet}" == "" ]]; then                                                                                                                        
        echo "No ${prefix_hdd} Drive"                                                                                                                                                          
        unlock                                                                                                                                                                                 
        exit 0                                                                                                                                                                                 
    fi                                                                                                                                                                                         
                                                                                                                                                                                               
    #mount all not mounted ntfs disk in usercontext                                                                                                                                            
    if [[ "${not_mountet}" != "" ]]; then                                                                                                                                                      
        while read -r disk;                                                                                                                                                                    
        do                                                                                                                                                                                     
            udisksctl mount -b "/dev/${disk}"                                                                                                                                                  
        done <<< "${not_mountet}"                                                                                                                                                              
    fi                                                                                                                                                                                         
                                                                                                                                                                                               
    #get a new list of mounted Sifi drives                                                                                                                                                     
    sifi_list=$(find gerlings/ krasser/ reichert/ hladigiworker/ -maxdepth 1 -type d -iname "${prefix_hdd}*")                                                                                  
                                                                                                                                                                                               
fi

# iterate over list of hdd
while read -r line;
do
    #check if already full uploaded
    if [[ -f "${default_base_path}/${line}/.automatic_upload_complete" ]]; then
        #for debug
        echo "Already completely uploaded, nothing to do."
        break
    fi

    # get hdd_name by using latest word (after latest slash)
    hdd_name=$(basename "${line}")
    # get current date
    current_date=$(date '+%F')
    # define empty hdd_name
    full_hdd_name_ingest=""

    # check if script has already created start file and skip md5 file creation if so
    if [[ -f "${default_base_path}/${line}/.automatic_upload_started" ]]; then
        echo "Not first time of running on this disk (${line}), skipping md5 file creation and retry upload"
        full_hdd_name_ingest=$(<"${default_base_path}/${line}/.automatic_upload_started")
    else
        #search for a corresponding md5 file in root folder of disk
        md5_file_count=$(find "${default_base_path}/${line}/" -maxdepth 1 -type f -name "*.md5" | wc -l)

        # if no md5 file was found, create one
        if [[ "${md5_file_count}" -eq 0 ]]; then
            rhash_list_file_path=$(find "${default_base_path}/${line}/" -maxdepth 1 -type f -name "*.rhash.txt")
            sifi_counter=$(cat /home/hladigiworker/sifi_counter.txt)
            (( sifi_counter++ ))
            # write to temporary file (if not it can abort with "operation not permitted")
            dos2unix -n "${rhash_list_file_path}" "/tmp/${sifi_counter}.unix"
            # move temp file back to original path
            mv -v "/tmp/${sifi_counter}.unix" "${rhash_list_file_path}.unix"
            # remove (windows) recycle folder, replace backslash with slash, remove all uppercase lines and write only the md5 checksum and filename to a new md5 file
            sed -e '/RECYCLE.BIN/d' -e 's=\\=/=g' -e 's=[[:upper:]]:/==' "${rhash_list_file_path}.unix" | awk -F'  ' '{print $3 "  " $1}' >> "${default_base_path}/${line}/sifi_${sifi_counter}.md5"

            # write new sifi counter to file (after checksum file creation)
            echo "${sifi_counter}" > /home/hladigiworker/sifi_counter.txt
            # define full_name of hdd in ingest
            full_hdd_name_ingest="${current_date}_${hdd_name}_${sifi_counter}"
            # write full_name of hdd in ingest to script start file to rely on it by script retries / restart with same hdd
            echo "${full_hdd_name_ingest}" > "${default_base_path}/${line}/.automatic_upload_started"
        fi

        # state that should not happen. Zero md5 files on start and one md5 file after creation. two (or more) md5 files is an error
        if [[ "${md5_file_count}" -gt 1 ]]; then
            echo "More than one md5 file... aborting!"
            unlock
            exit 1
        fi
    fi
    #Starting rsync to ceph
#    rsync -av -e "ssh -i /home/hladigiworker/.ssh/id_ed25519_automatic" "/media/${line}/" "hladigiingest@vhrz1653.hrz.uni-marburg.de:/${current_date}_${hdd_name}"
    #inspired by https://serverfault.com/a/219952
    trap "echo Exited!; exit;" SIGINT SIGTERM
    RSYNC_MAX_RETRIES=20
    counter=0
    # Set the initial return value to failure
    RSYNC_EXIT_STATUS=1
    # running rsync until exit status is zero (no error) or the retry counter is reached
    while [ "${RSYNC_EXIT_STATUS}" -ne 0 ] && [ "${counter}" -lt "${RSYNC_MAX_RETRIES}" ]
    do
        counter=$((counter+1))
        # disable shellcheck because we want to exclude the literally name of "$RECYCLE.BIN" (name in windows)
        # shellcheck disable=SC2016
        rsync -av --perms --chmod=D2770,F0660 --chown=:hladigi --exclude '$RECYCLE.BIN' --exclude 'System Volume Information' -e "ssh -i /home/hladigiworker/.ssh/id_ed25519_automatic -o ConnectTimeout=60 -o ServerAliveInterval=30 -o Serv>
        RSYNC_EXIT_STATUS="${?}"
    done

    if [[ "${counter}" -eq "${RSYNC_MAX_RETRIES}" ]]
    then
        echo "Hit maximum numbers of retries, giving up."
        unlock
        exit 1
    fi

    if [[ "${RSYNC_EXIT_STATUS}" -eq 0 ]]; then
        rm "${default_base_path}/${line}/.automatic_upload_started"
        touch "${default_base_path}/${line}/.automatic_upload_complete"
    fi

done <<< "${sifi_list}"
unlock
