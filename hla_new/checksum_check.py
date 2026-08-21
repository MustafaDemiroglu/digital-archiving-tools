#!/usr/bin/env python3

import multiprocessing
from concurrent.futures.process import ProcessPoolExecutor

import lib_hla_kitodo
lib_hla_kitodo.init()
from lib_hla_kitodo import *

checksum_error = False

# get all specific records from database
def get_all_database_records_by_full_sig_path(local_conn: psycopg.Connection, local_env_variables: dict,
                                              local_full_sig_path: str) -> list:
    # noinspection PyTypeChecker
    sql_query = sql.SQL("SELECT checksum_md5, full_path FROM {table} WHERE deleted_at IS NULL "
                        "AND {condition} like %s").format(
        table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
        condition=sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER'])
    )
    with local_conn.cursor() as cur:
        cur.execute(sql_query, (f"%{local_full_sig_path}/%",))
        query_result = cur.fetchall()
        return query_result

def md5sum_check(local_checksum: str, local_file_path: str) -> bool:
    try:
        result = subprocess.run(
            ['md5sum', local_file_path],
            capture_output=True,
            text=True,
            check=True
        )
        actual_md5 = result.stdout.split()[0]
        if actual_md5 == local_checksum:
            logging.info(f"successfully checked: {local_file_path}")
            return True
        else:
            logging.error(f"checksum did NOT match! please check: {local_file_path} | saved_checksum: {local_checksum} "
                          f"| calculated checksum: {actual_md5}")
            global checksum_error
            checksum_error = True
            return False
    except subprocess.CalledProcessError:
        logging.error("Error by calling subprocess for md5sum")
        sys.exit(1)

def main():
    start = time.time()
    # get database connection
    conn = get_database_connection(env_variables)
    item_count = 0
    database_records = get_all_database_records_by_full_sig_path(conn, env_variables, full_sig_path)
    if len(database_records) > 0:
        # get first record from database (checksum and path) and then get second element (only path)
        basepath = os.path.dirname(database_records[0][1])
        # count number of files (to check if number of checksum is equivalent to number of files to check)
        for path in os.listdir(basepath):
            if os.path.isfile(os.path.join(basepath, path)):
                item_count +=1
        if len(database_records) != item_count:
            logging.error("Database records count is NOT the same as local file count! Please check.")
            logging.error(f"Database records: {len(database_records)}  | Local file count: {item_count}")
            logging.fatal("Aborting for safety reason!")
            conn.close()
            sys.exit(1)
    else:
        logging.error(f"Could not found any record (or an error occurred) in database for the specified full_sig_path! "
                      f"{full_sig_path}")
        logging.fatal("Aborting for safety reason, please check.")
        conn.close()
        sys.exit(1)
    conn.close()
    checksum_executor = ProcessPoolExecutor(multiprocessing.cpu_count())
    executor_queue = []
    for record in database_records:
        executor_queue.append(checksum_executor.submit(md5sum_check, record[0], record[1]))
    checksum_executor.shutdown(wait=True)
    if checksum_error:
        logging.error("Error by checking checksums, please check! Aborting.")
        sys.exit(6)
    end = time.time()
    logging.info(f"Time for processing: {end - start} seconds")

if __name__ == '__main__':
    main()