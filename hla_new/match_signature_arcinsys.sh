#!/bin/bash
#check if xmlstarlet is installed
if ! command -v xmlstarlet &> /dev/null; then
    echo "xmlstarlet not found! (apt install xmlstarlet)"
    exit 1
fi
if [ -z "${1}" ]; then
    echo "need file path or list as first argument!"
    exit 1
fi
#find folder structure without files
if [[ -d "${1}" ]]; then
    echo "input parameter is a directory, searching for folders."
    item_list=$(find "${1}" -mindepth 3 -type d | sed "s=${1}==" | sed 's=^\(fremdarchivalien\|secure\)\/==' | sed 's=^[^\/]*\/[^\/]*$==' | sed '/^[[:space:]]*$/d')
elif [[ -f "${1}" ]]; then
    echo "input paremter is a file, using as list"
    item_list=$(< "${1}")
else
    echo "input is strange... aborting..."
    exit 1
fi
#define basex url without signature
url_basex="https://basex-hla.hrz.uni-marburg.de:443/searchbyfsig"
#define basex username
basex_user="vhrz2077_match_script"
#define basex password
basex_pw="tqqgvv5ZMNqvrfvwkQX7nQFyWx5yvPvNZXwqWpdvrPr5qiF9jgg54CiqUQJjnr7m79fcQjrjJHbk7dDmAPANdVgoqmfbaw5ZXhRSUAdmwW52VKx73afougL2zKJnmusY"
#define basex parameter
parameter_basex="identifier"
#define base path for file storage
base_path="/home/hladigiworker/check_sig"
#variables for filenames
filename_all_match="all_match.csv"
filename_all_multi_match="all_multi_match.csv"
filename_all_no_match="all_no_match.csv"
filename_all_match_only_inverzeichnung="all_match_only_inverzeichnung.csv"
#header for files
header_all="ArcinsysID,delivery"
header_only_inverzeichnung="${header_all},inverzeichnung_count,unitIDCUSTOM"

#genrate folder and parent if not exist
mkdir -p "${base_path}"
#create temp dir
base_path_tmp=$(mktemp --directory --tmpdir="${base_path}")
if [[ "${2}" == "" ]]; then
    #search md5 file
    full_md5_file=$(find "${1}" -mindepth 1 -maxdepth 1 -type f -name "*.md5")
    if [[ "${full_md5_file}" == "" ]]; then
        parent_path=$(dirname "${1}")
        full_md5_file=$(find "${parent_path}" -mindepth 1 -maxdepth 1 -type f -name "*.md5")
    fi
    #extract basename from md5 file path
    basename_full_md5=$(basename -s ".md5" "${full_md5_file}")
else
    #using input parameter for delivery field
    echo "Using second input parameter as delivery name"
    basename_full_md5="${2}"
fi
#create a all match file and begin with ID
echo "${header_all}" >> "${base_path_tmp}/${filename_all_match}"
#create a all multi_match file and begin with ID and delivery name
echo "${header_all}" >> "${base_path_tmp}/${filename_all_multi_match}"
#create a all no match file and begin with ID
echo "${header_all}" >> "${base_path_tmp}/${filename_all_no_match}"
#create a all_matched_only_inverzeichnung file and begin with ID and delivery name
echo "${header_only_inverzeichnung}" >> "${base_path_tmp}/${filename_all_match_only_inverzeichnung}"

# get number of lines in item_list variable for later progress status
item_list_length=$(echo "${item_list}" | wc -l)
# define counter to increment
item_list_counter=0

#iterate over every item from find
while read -r item; do
    # increase counter
    item_list_counter=$((item_list_counter+1))
    #check basex for item by signature
    arcid=$(curl --silent --fail --globoff "${url_basex}?${parameter_basex}=${item}&name=${basex_user}&pass=${basex_pw}")
    #convert output to only get ids without header and xml and only for items which are not an "inverzeichnung"
    xmlout=$(echo "${arcid}" | xmlstarlet sel -N TAXI="TAXI" -t -m "//TAXI:object[TAXI:item/TAXI:isinverzeichnung='false']" -v @id -n 2> /dev/null)
    #convert output to only get ids without header and xml and only for items which are an "inverzeichnung"
    xmlout_with_inverzeichnung=$(echo "${arcid}" | xmlstarlet sel -N TAXI="TAXI" -t -m "//TAXI:object[TAXI:item/TAXI:isinverzeichnung='true']" -v @id -n 2> /dev/null)

    #count the occurence of the letter 'v' (every arcinsysid starts with v)
    count=$(echo "${xmlout}" | grep -Fo v | wc -l)
    #check if original xmlout is empty (if so, no not inverzeichnung item was matched)
    if [[ "${count}" -eq 0 ]]; then
        #check if second list with inverzeichnung is not empty. (if so there is an inverzeichnung item without the original!)
        inv_count=$(echo "${xmlout_with_inverzeichnung}" | grep -Fo v | wc -l )
        if [[ "${inv_count}" -ne 0 ]]; then
            echo "List without inverzeichnung IS empty BUT list with inverzeichnung is NOT empty. So using this. Tell this Arcinsys!"
            echo "item: ${item}, count: ${inv_count} and \"first\" id in arcinsys: $(echo "${xmlout_with_inverzeichnung}" | head -n 1)"
            echo "$(echo "${xmlout_with_inverzeichnung}" | head -n 1),${basename_full_md5},${inv_count},${item}" >> "${base_path_tmp}/${filename_all_match_only_inverzeichnung}"
            #not abort execution (only informative)
        fi
        #no matching arcinsysid
        echo "No matching at all :( | Signatur: ${item} | ${item_list_counter}/${item_list_length}"
        echo "${item},${basename_full_md5}" >> "${base_path_tmp}/${filename_all_no_match}"
        continue
    fi

    #check if more than one arcinsysid
    if [[ "${count}" -gt 1 ]]; then
        echo "More than one matching, tell this Arcinsys! | Signatur: ${item} | ${item_list_counter}/${item_list_length}"
        temp_multimatch=$(echo -n "${item}___")
        temp_multimatch+=$(echo "${xmlout}" | tr " " "\n")
        #replace newline by ; and add to all multi match file
        echo "${temp_multimatch}" | awk -v ORS=";" '1' >> "${base_path_tmp}/${filename_all_multi_match}"
        #write newline to all multi match file
        echo ",${basename_full_md5}" >> "${base_path_tmp}/${filename_all_multi_match}"
        #abort execution (no more checking needed)
        continue
    #check if exactly one matching arcinsysid
    elif [[ "${count}" -eq 1 ]]; then
        echo "Exact one matching! | Signatur: ${item} | ArcinsysID: ${xmlout} | ${item_list_counter}/${item_list_length}"
        echo "${xmlout},${basename_full_md5}" >> "${base_path_tmp}/${filename_all_match}"
        #abort execution (no more checking needed)
        continue
    fi

done <<< "${item_list}"

#echo working directory
echo "working directory: ${base_path_tmp}"

# time elapsed
printf "Script has finished after "
printf '%02dh:%02dm:%02ds\n' $((SECONDS / 3600)) $((SECONDS % 3600 / 60)) $((SECONDS % 60))
