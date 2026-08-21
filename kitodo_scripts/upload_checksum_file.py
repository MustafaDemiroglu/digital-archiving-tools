#!/usr/bin/env python3
import shutil
from concurrent.futures.process import ProcessPoolExecutor

import lib_hla_kitodo
lib_hla_kitodo.init()
from lib_hla_kitodo import *

def checksum_validate_check(local_env_variables: dict, local_md5_file: Path, filetype_regex_name: str, ) -> bool:
    error_filename = f"{local_env_variables['KITODO_LOG_PATH']}/{current_date}_{filetype_regex_name}.txt"

    cmd = [
        'awk',
        '-v', f"allowed_filetype_input_regex={local_env_variables[filetype_regex_name]}",
        '-v', f"exclude_regex={local_env_variables['AWK_filetype_exclude_regex']}",
        '-f', local_env_variables['AWK_SCRIPT_PATH'],
        local_md5_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode == 0:
        logging.info(f"Execution of {filetype_regex_name} with regex {local_env_variables[filetype_regex_name]} was "
                     f"successfully.")
        return True
    else:
        logging.error(f"Error by validating file regex: {local_env_variables[filetype_regex_name]} "
                      f"Please see errors and filenames in file {error_filename}")
        if len(result.stdout) > 0:
            with open(error_filename, "a") as f:
                f.write(result.stdout)
        if len(result.stderr) > 0:
            logging.error(result.stderr)
        return False

def extract_and_prepare_md5_checksum_file(local_env_variables: dict, local_md5_file: Path) \
        -> list[str]:
    md5_list = []
    with open(local_md5_file) as file:
        while line := file.readline():
            tmp_list = line.split()
            file_name = os.path.basename(tmp_list[1])
            delivery = Path(os.path.basename(local_md5_file)).stem
            full_path = f"{local_env_variables['BASE_PATH_CEPH']}/{tmp_list[1]}"
            checksum_md5 = tmp_list[0]
            md5_list.append([file_name, delivery, full_path, checksum_md5])
    return md5_list


def insert_database_records(local_conn, local_env_variables: dict, records_to_add: list[str]) -> list[int]:
    logging.info("Creating temp table for insert...")
    # create temp table for later usage with COPY FROM
    # noinspection PyTypeChecker
    sql_query_temp_table = (sql.SQL(
        "CREATE TEMP TABLE {table} (file_name TEXT NOT NULL, delivery TEXT NOT NULL, full_path TEXT NOT NULL, "
        "checksum_md5 TEXT NOT NULL, dbentry_update TIMESTAMPTZ DEFAULT NOW())")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    with local_conn.cursor() as cur:
        cur.execute(sql_query_temp_table)

    logging.info("Inserting data to temp table (with COPY)...")
    # insert local records into temp table
    sql_query_copy_to_temp_table = (sql.SQL("COPY {table} (file_name, delivery, full_path, checksum_md5) FROM STDIN")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    with local_conn.cursor().copy(sql_query_copy_to_temp_table) as copy:
        for record in records_to_add:
            copy.write_row(record)
    logging.info("Commit changes to database")
    local_conn.commit()
    logging.info("Creating index ...")
    # create index on temp table for file_name column
    # noinspection PyTypeChecker
    sql_query_tt_ix_file_name = (sql.SQL(
        "CREATE INDEX IF NOT EXISTS idx_checksums_temp_kitodo_file_name ON {table} (file_name);")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    # create index on temp table for full_path column
    # noinspection PyTypeChecker
    sql_query_tt_ix_full_path = (sql.SQL(
        "CREATE INDEX IF NOT EXISTS idx_checksums_temp_kitodo_full_path ON {table} (full_path);")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    # create index on temp table for delivery column
    # noinspection PyTypeChecker
    sql_query_tt_ix_delivery = (sql.SQL(
        "CREATE INDEX IF NOT EXISTS idx_checksums_temp_kitodo_delivery ON {table} (delivery);")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    # create index on temp table for checksum_md5 column
    # noinspection PyTypeChecker
    sql_query_tt_ix_checksum_md5 = (sql.SQL(
        "CREATE INDEX IF NOT EXISTS idx_checksums_temp_kitodo_checksum_md5 ON {table} (checksum_md5);")
    .format(
        table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
    ))
    with local_conn.cursor() as cur:
        cur.execute(sql_query_tt_ix_file_name)
        cur.execute(sql_query_tt_ix_full_path)
        cur.execute(sql_query_tt_ix_delivery)
        cur.execute(sql_query_tt_ix_checksum_md5)

    logging.info("Commit changes to database")
    local_conn.commit()

    # noinspection PyTypeChecker
    sql_query_analyze_temp_table = (sql.SQL(
        "ANALYZE {temp_table}")
    .format(
        temp_table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
        table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME'])
    ))
    logging.info("Analyze temp table for faster access")
    with local_conn.cursor() as cur:
        cur.execute(sql_query_analyze_temp_table)

    logging.info("Commit changes to database")
    local_conn.commit()

    logging.info("Inner join temp table with checksum and count identical records...")
    # Inner join temp table and currently checksum table (to only get records which are in both tables)
    # and count this records (https://www.bakera.de/schule:joins)
    # noinspection PyTypeChecker
    sql_query_count_identical = (sql.SQL(
        "SELECT COUNT(*) FROM {temp_table} ctk INNER JOIN {table} c "
        "ON (ctk.file_name = c.file_name "
            "AND ctk.delivery = c.delivery "
            "AND ctk.full_path = c.full_path "
            "AND ctk.checksum_md5 = c.checksum_md5 "
            "AND deleted_at IS NULL)")
    .format(
        temp_table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
        table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME'])
    ))
    identical_record_count = 0
    with local_conn.cursor() as cur:
        cur.execute(sql_query_count_identical)
        identical_record_count = cur.fetchone()[0]

    # check if the identical record count is greater than zero, if so there are 1:1 duplicates in the import temp table
    if identical_record_count > 0:
        # get all duplicate records
        # noinspection PyTypeChecker
        sql_query = (sql.SQL(
            "SELECT c.file_name, c.delivery, c.full_path, c.checksum_md5 FROM {temp_table} ctk INNER JOIN {table} c "
            "ON (ctk.file_name = c.file_name "
                "AND ctk.delivery = c.delivery "
                "AND ctk.full_path = c.full_path "
                "AND ctk.checksum_md5 = c.checksum_md5 "
                "AND deleted_at IS NULL)")
        .format(
            temp_table=sql.Identifier(local_env_variables['DATABASE_TEMP_TABLE_NAME']),
            table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME'])
        ))
        with local_conn.cursor() as cur:
            cur.execute(sql_query)
            duplicate_records = cur.fetchall()

        # Not an error, therefore only a waring is logged and the duplicate records are ignored
        logging.warning(f"There are {identical_record_count} out of {len(records_to_add)} record(s) already in the "
                        f"database!")
        logging.warning("These records are ignored and will NOT be imported again!")
        logging.warning("Affected records (one per line):")
        for record in duplicate_records:
            logging.warning(record)

        # if the complete temp table / md5_file is already completely inserted in the checksum table this is an error
        # and need manual checking (this should only happen if a md5 file is uploaded / inserted again)
        if len(records_to_add) == identical_record_count:
            logging.error("ALL database records to add are already inserted. file_name, delivery, full_path and the "
                             "checksum_md5 are identical! This needs an manual check! Aborting.")
            sys.exit(1)

    logging.info("Inserting data to checksum table over internal insert_over_kitodo function")
    # execute function hla_checksum_insert_over_kitodo in postgres database. This marks old records as deleted and
    # insert the records to the database. you get the number of inserted records back.
    sql_query_insert_kitodo_function = (sql.SQL("SELECT hla_checksum_insert_over_kitodo()"))
    records_inserted=0
    with local_conn.cursor() as cur:
        cur.execute(sql_query_insert_kitodo_function)
        records_inserted = cur.fetchone()[0]

    # make all changes persistent
    local_conn.commit()
    return [records_inserted, identical_record_count]

def copy_checksum_file_to_ceph(local_env_variables, md5_file):
    try:
        if not Path(f"{local_env_variables['BASE_PATH_MANIFEST']}/{md5_file.name}").is_file():
            return shutil.copy2(md5_file, f"{local_env_variables['BASE_PATH_MANIFEST']}/{md5_file.name}")
        else:
            logging.error("File already exists in destination directory (ceph manifest). Aborting!")
            return False
    except IOError as e:
        logging.error("Error by copying md5 checksum file to ceph!")
        logging.error(e)
        return False

def main():
    # init specific global variables and reimport them for usage
    init_hdd_folder_in_upload_directory(cli_arguments, env_variables)
    from lib_hla_kitodo import hdd_root_folder

    start = time.time()

    check_file = Path(f"{env_variables['BASE_PATH_HDD_INGEST_CEPH']}/{hdd_root_folder}"
                      f"/.checksum_file_successfully_uploaded")
    if check_file.is_file():
        logging.info("Checksum file was already uploaded, nothing to do.")
        sys.exit(0)

    md5_file = Path(f"{env_variables['BASE_PATH_HDD_INGEST_CEPH']}/{hdd_root_folder}"
                    f"/{cli_arguments['meta_delivery']}.md5")

    if not md5_file.is_file():
        logging.error(f"md5 file not found under {md5_file} please check! Aborting.")
        sys.exit(2)

    filetype_regex_list = ['AWK_filetype_regex_strict',
                           'AWK_filetype_regex_lax']

    with ProcessPoolExecutor(max_workers=3) as executor:
        process_list = []
        for filetype_regex_name in filetype_regex_list:
            process_list.append(executor.submit(checksum_validate_check, env_variables, md5_file,
                                                filetype_regex_name))

    executor.shutdown(wait=True)
    if not all(proc.result() for proc in process_list):
        logging.error("Error while validating filetype regex in md5 file. Aborting.")
        sys.exit(1)

    conn = get_database_connection(env_variables)
    full_md5_records = extract_and_prepare_md5_checksum_file(env_variables, md5_file)
    records_inserted, identical_records = insert_database_records(conn, env_variables, full_md5_records)
    if records_inserted == len(full_md5_records)-identical_records:
        logging.info(f"Successfully inserted checksum data to manifest. {records_inserted} record(s) was/were added")
        Path(check_file).touch()
    else:
        logging.fatal("Error by inserting checksum data to database! See errors above. Please check!")
        conn.close()
        sys.exit(1)
    conn.close()

    if copy_checksum_file_to_ceph(env_variables, md5_file):
        logging.info("Original md5 checksum file was successfully copied to ceph")
    else:
        logging.error("Error while copying md5 checksum file to ceph! Aborting.")
        sys.exit(1)

    end = time.time()
    logging.info(f"Insert took {end - start} seconds")

if __name__ == '__main__':
    main()
