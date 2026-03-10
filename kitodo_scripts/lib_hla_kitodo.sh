#!/bin/bash

# fail if anything of pipeline failed
set -o pipefail

# all script need the following parameter from kitodo: {"kitodo_processid": "(processid)", "kitodo_processtitle": "(processtitle)", "kitodo_stepname": "(stepname)", "meta_document_type": "${meta.document_type}", "meta_unitIDCUSTOM": "${meta.unitIDCUSTOM}", "meta_archiveNameCUSTOM": "${meta.archiveNameCUSTOM}", "meta_stockUnitIDCUSTOM": "${meta.stockUnitIDCUSTOM}", "meta_protection_until": "${meta.protection_until}", "meta_hidden_until": "${meta.hidden_until}", "meta_delivery": "${meta.delivery}", "jpg_quality": "${meta.JPGQuality}", "maxsize_x": "meta.MaxSizeX", "maxsize_y": "${meta.MaxSizeY}"}
# if not running over kitodo, replace first '{' and last '}' with '(' and ')' because Kitodo is doing the same
# define basic 'static' variables
group="hladigi"
base_path_ceph="/media/cepheus"
base_path_hdd_ingest_ceph="${base_path_ceph}/ingest/hdd_upload"
# shellcheck disable=SC2034
# used external
base_path_manifest="${base_path_ceph}/manifest"
manifest_all="${base_path_ceph}/manifest/all/all_for_checking.md5"
kitodo_base_path="/usr/local/kitodo"
# shellcheck disable=SC2034
# used external
kitodo_metadata_path="${kitodo_base_path}/metadata"
# shellcheck disable=SC2034
# used external
kitodo_img_max_name="max"
# shellcheck disable=SC2034
# used external
kitodo_img_thumb_name="thumbs"
# shellcheck disable=SC2034
# used external
kitodo_img_tiff_name="tiff"
# shellcheck disable=SC2034
# used external
netapp_path="/media/archive/public"
# shellcheck disable=SC2034
# used external
additional_output_folder_netapp="www"

# check if date command is installed
if ! command -v date &> /dev/null
then
    echo "Date command not installed! Please install. (apt install date)"
    exit 1
fi

# check if jq command is installed
if ! command -v jq &> /dev/null
then
    echo "JQ command not installed! Please install. (apt install jq)"
    exit 1
fi

current_date=$(date '+%Y-%m-%d')

# function for read input stream, replace wrong brackets and convert to valid json string for jq
function read_parameters_and_export_json_to_env () {
    # read complete input parameters as one string ($*) and replace first occurrence of open round bracket and last occurrence of close round bracket with curly brackets
    json=$(echo "${*}" | sed '0,/(/{s/(/\{/}' | sed 's/\(.*\))/\1}/')
    # iterate over jq output
    while read -r LINE; do
        export "${LINE?}"
    # convert all input parameters to key value pairs with jq and simple output it with newlines
    done < <(echo "${json}" | jq --compact-output --raw-output --monochrome-output 'to_entries | map("\(.key)=\(.value)") | .[]')
}

read_parameters_and_export_json_to_env "${*}"

# define script name, logfile name and logfile path
script_name=$(basename -s '.sh' "${0}")
# shellcheck disable=SC2154
# exported as env over read_parameters_and_export_json_to_env function
logfile_name="${current_date}_${script_name}_${kitodo_processid}.log"
logfile_path="${kitodo_base_path}/logs/${logfile_name}"

# create logfile with (hopefully) correct permissions and group
sg "${group}" -c "touch ${logfile_path}"

# check if standard input and standard (and error) output is terminal device (running from terminal)
# if so than also output to terminal
# TODO add prefix for log messages with current date, script name and process id
if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then
    exec &> >(tee -a "${logfile_path}")
# if not only logging to logfile
else
    exec &> >(tee -a "${logfile_path}" > /dev/null)
fi

# shellcheck disable=SC2154
# exported as env over read_parameters_and_export_json_to_env function
if [ "${meta_document_type}" == "Stock" ]; then
    echo "This is a stock! Nothing to do."
    exit 0
fi

# shellcheck disable=SC2154
# exported as env over read_parameters_and_export_json_to_env function
# check if at least the first 3 arguments where given / not empty
if [ "${kitodo_processid}" == "" ] || [ "${kitodo_processtitle}" == "" ] || [ "${meta_unitIDCUSTOM}" == "" ]; then
    echo "Sorry this script needs at least 3 arguments to working correctly!"
    exit 99
fi

# define most parameter variables with given arguments
# shellcheck disable=SC2154
# exported as env over read_parameters_and_export_json_to_env function
archive_sig="${meta_archiveNameCUSTOM}"
# shellcheck disable=SC2154
# exported as env over read_parameters_and_export_json_to_env function
fond_sig="${meta_stockUnitIDCUSTOM}"
vze_sig="${meta_unitIDCUSTOM}"

# define and init some variables for later use
vze_unknown="false"
vze_multi="false"
full_sig_path="${archive_sig}/${fond_sig}/${vze_sig}"
folder_path="UNKNOWN"
full_hdd_folders="UNKNOWN"
hdd_root_folder="UNKNOWN"
hdd_sub_folder="UNKNOWN"
vze_accessrestrict="true"

umask 007

# check if process is unknown and set path
case "${meta_document_type}" in
    Unknown)
        vze_unknown="true"
        full_sig_path="${vze_sig}"
	    vze_accessrestrict="false"
        meta_protection_until=0
        meta_hidden_until=0
        meta_fond_protection_until=0
        meta_fond_hidden_until=0
        ;;

    Multimatch)
        # shellcheck disable=SC2034
        # used external
        vze_unknown="true"
        # shellcheck disable=SC2034
        # used external
        vze_multi="true"
        full_sig_path="${vze_sig}"
	    vze_accessrestrict="false"
        meta_protection_until=0
        meta_hidden_until=0
        meta_fond_protection_until=0
        meta_fond_hidden_until=0
        ;;

esac

# shellcheck disable=SC2034
# used external
relativ_path_ceph=$(grep "${full_sig_path}/" "${manifest_all}" | cut -d' ' -f3 | rev | cut -d'/' -f2- | rev | sort -u)

# check if invoked scripts is one of the named one and if so skip checking for relative_path_ceph because not needed in this case
if ! { [[ "${script_name}" == "secure_check" ]] || [[ "${script_name}" == "move_ingest2ceph" ]] || [[ "${script_name}" == "upload_checksum_file" ]] || [[ "${script_name}" == "rename_according_to_processtitle" ]] || [[ "${script_name}" == "derivate_generation_2" ]]; }; then
    if [[ "${relativ_path_ceph}" == "" ]]; then
        echo "Full Signature Path ${full_sig_path} not found in manifest ${manifest_all}."
        echo "Manually intervention required! Aborting."
        exit 4
    fi
fi

echo "Invoking script ${script_name} with following parameters : $*"

number_regex='^[0-9]+$'

if [[ ! "${meta_protection_until}" =~ $number_regex ]] || [[ ! "${meta_hidden_until}" =~ $number_regex ]] || [[ ! "${meta_fond_hidden_until}" =~ $number_regex ]] || [[ ! "${meta_fond_protection_until}" =~ $number_regex ]]; then
        echo "No no no, one of the protection or hidden year number is NOT a number! Please check. Aborting."
        exit 3
fi
# define list of specific protection_until value
# 4444 (Kennzeichnung fehlend oder vermisst), 4455 (falsche Signatur, aber im Moment nicht korrigierbar), 4466 (Aus Lagerungsgründen nicht nutzbar), 5555 (aus konservatorischen Gründen nicht nutzbar),
# 5566 (provisorische Nutzungssperre aus konservatorischen Gründen), 5577 (Sperrung von "Zimelien", Erhaltung finanzieller Wert)
# https://unimarburg.plan.io/attachments/75265
exclude_protection_until_years="4444 4455 4466 5555 5566 5577"

# check if current meta_protection_until (and fond) is in list of exceptions if so set year to zero
# DELIMITER is whitespace (see list above)
DELIMITER=" "
if [[ "${exclude_protection_until_years}" =~ (${DELIMITER}|^)${meta_fond_protection_until}(${DELIMITER}|$) ]]; then
    meta_fond_protection_until=0
fi
if [[ "${exclude_protection_until_years}" =~ (${DELIMITER}|^)${meta_protection_until}(${DELIMITER}|$) ]]; then
    meta_protection_until=0
fi
# define current year
current_year=$(date +%Y)

# calculate hidden and protection until
protection_year_minus_current=$((meta_protection_until-current_year))
hidden_year_minus_current=$((meta_hidden_until-current_year))
fond_protection_year_minus_current=$((meta_fond_protection_until-current_year))
fond_hidden_year_minus_current=$((meta_fond_hidden_until-current_year))

if [[ "${protection_year_minus_current}" -lt 0 ]] && [[ "${hidden_year_minus_current}" -lt 0 ]] && [[ "${fond_protection_year_minus_current}" -lt 0 ]] && [[ "${fond_hidden_year_minus_current}" -lt 0 ]]; then
    vze_accessrestrict="false"
fi
echo "Protection status: ${vze_accessrestrict}"

# define some functions

# define function to determine current location of folder corresponding to signature and fill variables based on result
function search_folder_vze () {
    # shellcheck disable=SC2154
    # exported as env over read_parameters_and_export_json_to_env function
    # find corresponding delivery checksum file
    checksum_file_path=$(find "${base_path_hdd_ingest_ceph}" -maxdepth 2 -mindepth 2 -type f -name "${meta_delivery}.md5")
    # check if exact one checksum file was found
    if [[ $(echo "${checksum_file_path}" | wc -l) -ne 1 ]]; then
        echo "More (or less) than one matched checksum delivery file, please check! Aborting."
        exit 2
    fi
    #md5 file (to support legacy use of variable)
    # shellcheck disable=SC2034
    md5_file="${checksum_file_path}"
    # extract hdd path from checksum file (always in root directory)
    full_hdd_folder_path=$(dirname "${checksum_file_path}")
    # search in corresponding hdd for full_sig_path
    folder_path=$(find "${full_hdd_folder_path}" -path "*/${full_sig_path}")
    # check if find is empty (nothing was found...)
    if [[ $(echo "${folder_path}" | wc -l) -ne 1 ]]; then
        echo "More (or less) than one matched filepath, please check! Aborting."
        exit 1
    fi
    # set vze to access restricted if folder path contains secure
    if [[ "${folder_path}" == *"/secure/"* ]]; then
        vze_accessrestrict="true"
    fi
    #extract full hdd folder name from path
    full_hdd_folders=$(echo "${folder_path}" | sed "s=secure/==g" | sed "s=/${full_sig_path}==g" | sed "s=${base_path_hdd_ingest_ceph}/==g")
    #extract only hdd name from path
    # shellcheck disable=SC2034
    hdd_root_folder=$(echo "${full_hdd_folders}" | cut -d/ -f1)
    #extract sub hdd folder from path
    # shellcheck disable=SC2034
    # used external
    hdd_sub_folder=$(echo "${full_hdd_folders}" | cut -s -d/ -f2-)
}
