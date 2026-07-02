#!/usr/bin/env python3

import lib_hla_kitodo
lib_hla_kitodo.init()
from lib_hla_kitodo import *

# function for reading csv/txt file.
def read_file(local_file: Path) -> list[str]:
    # check if file is txt (currently only pure textfiles with one entry per line are supported!)
    if local_file.suffix == '.txt':
        return_list=[]
        # read paths from file and create list
        with open(local_file) as file:
            for num, line in enumerate(file, 1):
                if num == 1:
                    local_file_mode = line.rstrip()
                    match local_file_mode:
                        case "RELATIVE":
                            pass
                        case "CHECKSUM":
                            pass
                        case _:
                            logging.error(f"The given filemode is NOT supported! Currently only RELATIVE and "
                                          f"CHECKSUM are supported. First line in file is: {line} file_mode: "
                                          f"{local_file_mode}")
                            sys.exit(1)
                return_list.append(line.rstrip())
            return return_list
    else:
        logging.error(f"The given file is not supported for deletion. Please check file extension: {local_file.suffix}")
        sys.exit(1)


def ids_by_paths(local_conn, local_env_variables: dict, local_deletion_list: list[str]) -> list[int]:
    # noinspection PyTypeChecker
    sql_query_get_ids_by_like_path = sql.SQL(
        "SELECT array_agg(id) FROM {table} WHERE deleted_at is NULL AND {condition} like ANY(%s)").format(
            table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
            condition=sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER'])
        )
    # noinspection PyTypeChecker
    sql_query_get_ids_by_path = sql.SQL(
        "SELECT array_agg(id) FROM {table} WHERE deleted_at is NULL AND {condition} = ANY(%s)").format(
            table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
            condition=sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER'])
        )
    with local_conn.cursor() as cur:
        to_execute=[]
        to_execute_like=[]
        for item in local_deletion_list:
            if item[-1] == "/":
                to_execute_like.append(f"%{item}%")
            else:
                to_execute.append(f"{local_env_variables['BASE_PATH_CEPH']}/{item}")
        all_results = []
        if len(to_execute) > 0:
            cur.execute(sql_query_get_ids_by_path, [to_execute])
            tmp_result = cur.fetchone()
            if len(tmp_result) != tmp_result.count(None):
                all_results.extend(tmp_result[0])
        if len(to_execute_like) > 0:
            cur.execute(sql_query_get_ids_by_like_path, [to_execute_like])
            tmp_result = cur.fetchone()
            if len(tmp_result) != tmp_result.count(None):
                all_results.extend(tmp_result[0])
        return all_results


def ids_by_checksum(local_conn, local_env_variables: dict, local_deletion_list: list[str]) -> list[int]:
    # noinspection PyTypeChecker
    sql_query_get_ids_by_checksums = sql.SQL(
        "SELECT array_agg(id) FROM {table} WHERE deleted_at is NULL AND {condition} = ANY(%s)").format(
        table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
        condition=sql.Identifier(local_env_variables['DATABASE_TABLE_CHECKSUM_IDENTIFIER'])
    )
    with local_conn.cursor() as cur:
        cur.execute(sql_query_get_ids_by_checksums, [local_deletion_list])
        tmp_result = cur.fetchone()
        if len(tmp_result) != tmp_result.count(None):
            return tmp_result[0]
        return []


def soft_delete_rows_by_ids(local_conn, local_deletion_list: list[int]):
    sql_query_soft_delete_by_id = sql.SQL("SELECT * FROM hla_soft_delete_checksums(%s)")
    with local_conn.cursor() as cur:
        tmp_result = cur.execute(sql_query_soft_delete_by_id, [local_deletion_list]).fetchone()
        if len(tmp_result) != tmp_result.count(None):
            return tmp_result[0]
        return 0


def main():
    start = time.time()
    # get database connection
    conn = get_database_connection(env_variables)

    # same logic as with normal delivery, search folder by delivery.md5 file and then use
    # init specific global variables and reimport them for usage
    init_hdd_folder_in_upload_directory(cli_arguments, env_variables)
    from lib_hla_kitodo import hdd_root_folder

    # load manifest_deletion.txt file from hdd_root_folder
    local_file = Path(f"{env_variables['BASE_PATH_HDD_INGEST_CEPH']}/{hdd_root_folder}"
                    f"/manifest_deletion.txt")

    if not local_file.is_file():
        logging.error(f"local file not found under {local_file} please check! Aborting.")
        sys.exit(2)

    deletion_list = read_file(local_file)
    ids_to_delete = []
    match deletion_list[0]:
        case "RELATIVE":
            del deletion_list[0]
            ids_to_delete.extend(ids_by_paths(conn, env_variables, deletion_list))
        case "CHECKSUM":
            del deletion_list[0]
            ids_to_delete.extend(ids_by_checksum(conn, env_variables, deletion_list))
        case _:
            logging.error(f"The given filemode is NOT supported! Currently only RELATIVE and "
                          f"CHECKSUM are supported.")
            sys.exit(1)

    if len(ids_to_delete) > 0:
        deleted_records = soft_delete_rows_by_ids(conn, ids_to_delete)
        if len(ids_to_delete) != deleted_records:
            logging.error("Not all of the identified IDs were soft deleted!")
            logging.error(f"ID count: {len(ids_to_delete)} vs. deleted records count: {deleted_records}")
            logging.error("Rolling back...")
            conn.rollback()
        else:
            logging.info("Commit changes to database...")
            conn.commit()
    else:
        logging.error("Nothing was found for deletion. Please check!")
        sys.exit(1)

    logging.info("Closing database connection, all done")
    conn.close()
    end = time.time()
    logging.info(f"Time for processing: {end - start} seconds")

if __name__ == '__main__':
    main()
