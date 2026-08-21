#!/bin/bash
# needs following input parameter "fullpath_to_checksum_file" "kitodo_processid" "kitodo_processtitle"
# and optional "meta_delivery"

# library not needed so not sourcing it!

# get variables from input parameter
fullpath_to_checksum_file="${1}"
name_checksum_file=$(basename "${fullpath_to_checksum_file}")
kitodo_processid="${2}"
kitodo_processtitle="${3}"
meta_delivery="${4}"

# define secret gitlab api token. This token need FULL api access (read/write)
gitlab_api_token="glpat-fgzRX-pVmkqSTzMJH2j2"
# define project url of gitlab manifest (hla only using one manifest, so hardcoded should be fine)
gitlab_base_repo_project_url="https://gitlab.hrz.uni-marburg.de/api/v4/projects/777"

# check if checksum file exist
if [ ! -f "${fullpath_to_checksum_file}" ]; then
    echo "Checksum file not found! Aborting."
    exit 1
fi

gitlab_file_upload () {
    curl --silent --request "${1}" --header "PRIVATE-TOKEN: ${gitlab_api_token}" \
        --form "branch=kitodo_${kitodo_processid}" \
        --form "start_branch=main" \
        --form "author_email=hla-repo@uni-marburg.de" \
        --form "author_name=Kitodo Prod" \
        --form "commit_message=Upload checksum file ${name_checksum_file}" \
        --form "file_path=${name_checksum_file}" \
        --form "content=<${fullpath_to_checksum_file}" \
        "${gitlab_base_repo_project_url}/repository/files/${name_checksum_file}"
}

gitlab_create_mergerequest () {
    curl --silent --request POST --header "PRIVATE-TOKEN: ${gitlab_api_token}" \
        --form "source_branch=kitodo_${kitodo_processid}" \
        --form "target_branch=main" \
        --form "title=Merge kitodo_${kitodo_processid} with ${name_checksum_file} to main" \
        --form "description=**Automatic merge request kitodo:** <br /><br /> **process_id:** ${kitodo_processid}  <br /> **process_title:** ${kitodo_processtitle}  <br /> **md5 checksum filename:** ${name_checksum_file} <br /> **delivery:** ${meta_delivery}  <br />  <br /> Please review changes and merge if everything is correct." \
        --form "allow_collaboration=true" \
        --form "remove_source_branch=true" \
        --form "assignee_id=464" \
        "${gitlab_base_repo_project_url}/merge_requests"
}

echo "Uploading file to gitlab manifest under ${gitlab_base_repo_project_url}"
upload_output=$(gitlab_file_upload POST)

if [[ "$(echo "${upload_output}" | jq .message | tr -d '"')" == "A file with this name already exists" ]]; then
    echo "File already exist! Trying to Update"
    upload_output=$(gitlab_file_upload PUT)
fi

if [[ "$(echo "${upload_output}" | jq .file_path | tr -d '"')" != "${name_checksum_file}" ]]; then
    echo "Error by uploading to gitlab, please check! Aborting."
    echo "${upload_output}"
    echo "${name_checksum_file} | ${fullpath_to_checksum_file}"
    exit 6
else
    echo "Successfully uploaded checksum file to gitlab."
    echo "Creating Merge-Request"
    create_merge_output=$(gitlab_create_mergerequest)

    if [[ "$(echo "${create_merge_output}" | jq .title | tr -d '"')" == "Merge kitodo_${kitodo_processid} with ${name_checksum_file} to main" ]]; then
        echo "Upload script successfully completed"
        exit 0
    else
        echo "Error on Creating Merge-Request! Please check."
        exit 7
    fi
fi
