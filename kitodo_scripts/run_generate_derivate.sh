### run_generate_derivate.sh

kitodo_process_folder="${kitodo_metadata_path}/${kitodo_processid}/images"

cd "${kitodo_process_folder}" || exit 1

tmp_folder="/tmp/kitodo/${kitodo_processid}"
mkdir -p "${tmp_folder}"
output_folder_path="${kitodo_process_folder}"
generation_list_path="${tmp_folder}/stuecke.txt"
generation_list_path_only_preview="${tmp_folder}/stuecke_preview.txt"