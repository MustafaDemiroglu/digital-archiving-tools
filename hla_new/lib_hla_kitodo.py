import grp
import logging
import os
import sys
import time
import subprocess

# import datetime to use date functions (e.g. for filenames)
from datetime import date
from pathlib import Path

# import dotenv to load database credentials (and maybe other variables also later?)
import dotenv

# import psycopg for simple, better and secure sql handling
import psycopg

# import json for working with json
import json

from psycopg import sql

# define global variables for later usage and export
env_variables: dict
cli_arguments: dict
current_date: str = ""

archive_sig: str = "UNKNOWN"
fond_sig: str = "UNKNOWN"
vze_sig: str = "UNKNOWN"

vze_unknown: bool = False
vze_multi: bool = False
full_sig_path: str = "UNKNOWN"
folder_path: str = "UNKNOWN"
full_hdd_folders: str = "UNKNOWN"
hdd_root_folder: str = "UNKNOWN"
hdd_sub_folder: str = "UNKNOWN"
vze_accessrestrict: bool = True

def read_command_line_input_parameter(local_env_variables: dict) -> dict:
    # read command line arguments, all at ones and rejoin them with spaces (like the original call)
    cli_input = ' '.join(sys.argv[1:])
    # load fake json string from input and replace first occurrence of '(' and last occurrence of ')' with '{' and '}'
    json_input_tmp = "}".join(cli_input.replace('(', '{', 1).rsplit(')', 1))
    # load the now working json string and return it as json object
    json_input_object = json.loads(json_input_tmp)
    return cli_arguments_validation(json_input_object, local_env_variables)

def read_env_variables_from_file() -> dict:
    if Path(".env").is_file():
        return dotenv.dotenv_values(".env")
    elif Path("/etc/hla/.env").is_file():
        return dotenv.dotenv_values("/etc/hla/.env")
    else:
        print("Cant find local .env file! Aborting.")
        sys.exit(1)

def get_script_name() -> str:
    return os.path.basename(sys.argv[0]).replace('.py', '', 1)

def set_correct_group_and_permission(path: Path | str, group_name: str, mode: int) -> None:
    gid = grp.getgrnam(group_name).gr_gid
    os.chown(path, -1, gid)
    os.chmod(path, mode)

def add_local_console_to_logger() -> None:
    console = logging.StreamHandler()
    console.setLevel(logging.DEBUG)
    # set a format which is simpler for console use
    formatter = logging.Formatter('%(name)-12s: %(levelname)-8s %(message)s')
    console.setFormatter(formatter)
    # add the handler to the root logger
    logging.getLogger('').addHandler(console)

def is_fond(document_type: str, excepted_type: str) -> bool:
    if document_type == excepted_type:
        return True
    else:
        return False

def cli_arguments_validation(local_cli_arguments: dict, local_env_variables: dict) -> dict:
    local_cli_arguments = special_protection_until_evaluation(local_cli_arguments, local_env_variables)
    if (local_cli_arguments['kitodo_processid'] == "" or local_cli_arguments['kitodo_processtitle'] == "" or
            local_cli_arguments['meta_unitIDCUSTOM'] == ""):
        logging.fatal("Sorry this script needs at least 'kitodo_processid', 'kitodo_processtitle' and "
                      "'meta_unitIDCUSTOM' to working correctly!")
        sys.exit(1)
    try:
        local_cli_arguments['meta_protection_until'] = int(local_cli_arguments['meta_protection_until'])
        local_cli_arguments['meta_hidden_until'] = int(local_cli_arguments['meta_hidden_until'])
        local_cli_arguments['meta_fond_hidden_until'] = int(local_cli_arguments['meta_fond_hidden_until'])
        local_cli_arguments['meta_fond_protection_until'] = int(local_cli_arguments['meta_fond_protection_until'])
    except ValueError:
        if local_cli_arguments['meta_document_type'] in ['Unknown', 'Multimatch']:
            local_cli_arguments['meta_protection_until'] = 0
            local_cli_arguments['meta_hidden_until'] = 0
            local_cli_arguments['meta_fond_hidden_until'] = 0
            local_cli_arguments['meta_fond_protection_until'] = 0
            return local_cli_arguments
        logging.fatal("Sorry but at least one of the protection or hidden value is not a int number! "
                      "Aborting for safety reason!")
        sys.exit(1)
    return local_cli_arguments

def special_protection_until_evaluation(local_cli_arguments: dict, local_env_variables: dict) -> dict:
    local_exclude_protection_until_years = local_env_variables['EXCLUDE_PROTECTION_UNTIL_YEARS'].split(' ')
    if local_cli_arguments['meta_protection_until'] in local_exclude_protection_until_years:
        local_cli_arguments['meta_protection_until'] = 0
    if local_cli_arguments['meta_fond_protection_until'] in local_exclude_protection_until_years:
        local_cli_arguments['meta_fond_protection_until'] = 0
    return local_cli_arguments

def is_access_restricted(local_cli_arguments: dict) -> bool:
    access_restricted = True
    current_year = int(date.today().strftime('%Y'))
    if (local_cli_arguments['meta_protection_until'] - current_year < 0 and
            local_cli_arguments['meta_hidden_until'] - current_year < 0 and
            local_cli_arguments['meta_fond_hidden_until'] - current_year < 0 and
            local_cli_arguments['meta_fond_protection_until'] -current_year < 0):
        access_restricted = False
    return access_restricted

def get_database_connection(local_env_variables: dict) -> psycopg.Connection:
    try:
        conn = psycopg.connect(host=local_env_variables['DATABASE_HOST'], port=local_env_variables['DATABASE_PORT'],
                             dbname=local_env_variables['DATABASE_NAME'], user=local_env_variables['DATABASE_USERNAME'],
                             password=local_env_variables['DATABASE_PASSWORD'])
        conn.add_notice_handler(log_notice)
        return conn
    except psycopg.Error as e:
        logging.fatal(f'Error occurred in psycopg: ${e}')
        sys.exit(1)

def log_notice(diag):
    logging.info(f"Message from server: {diag.severity} - {diag.message_primary}")

def init_hdd_folder_in_upload_directory(local_cli_arguments: dict, local_env_variables: dict) -> None:
    # this method is NOT using best practise with overwriting global variables...
    # but for now this is most like the bash script.
    md5_filename = f"{local_cli_arguments['meta_delivery']}.md5"
    upload_directory = Path(local_env_variables['BASE_PATH_HDD_INGEST_CEPH'])
    path_signature = full_sig_path

    # Durchlaufe alle Verzeichnisse mit genau 2 Ebenen Tiefe
    try:
        result = subprocess.run(
            ['find', upload_directory, '-maxdepth', '2', '-mindepth', '2', '-type', 'f', '-name', md5_filename],
            capture_output=True,
            text=True,
            check=True
        )
        full_path_md5_file = result.stdout.splitlines()
    except subprocess.CalledProcessError:
        logging.error("Error by calling subprocess for find")
        sys.exit(1)
    if len(full_path_md5_file) > 1:
        logging.fatal(f"Found more than one md5file for specific delivery: {local_cli_arguments['meta_delivery']}")
        sys.exit(1)
    if len(full_path_md5_file) < 1:
        logging.fatal("Cant find any local md5 file, so it is impossible to get the local hdd folder!")
        sys.exit(1)
    md5_dir_path = os.path.dirname(full_path_md5_file[0])

    try:
        result = subprocess.run(
            ['find', md5_dir_path, '-path', f"*/{full_sig_path}"],
            capture_output=True,
            text=True,
            check=True
        )
        local_folder_path = result.stdout.splitlines()
    except subprocess.CalledProcessError:
        logging.error("Error by calling subprocess for find")
        sys.exit(1)

    if len(local_folder_path) > 1:
        logging.fatal(f"Found more than one folder for specific signature path: {path_signature}")
        sys.exit(1)
    if len(local_folder_path) < 1:
        logging.fatal(f"Cant find any folder for the specific signature path: {path_signature}")
        sys.exit(1)

    global folder_path
    folder_path = local_folder_path[0]

    if "secure" in folder_path:
        global vze_accessrestrict
        vze_accessrestrict=True

    global full_hdd_folders
    # remove secure, full_sig_path and the upload_directory from the path to only get the
    full_hdd_folders = (folder_path
                        .replace('secure/', '', 1)  # Nur erste Vorkommen ersetzen
                        .replace(f"/{full_sig_path}", '', 1)
                        .replace(f"{upload_directory}/", '', 1))

    global hdd_root_folder
    hdd_root_folder = full_hdd_folders.split('/')[0] if full_hdd_folders else ''

    global hdd_sub_folder
    hdd_sub_folder = '/'.join(full_hdd_folders.split('/')[2:]) if len(full_hdd_folders.split('/')) > 2 else ''

def get_dirname_by_signature(local_conn: psycopg.Connection, local_env_variables: dict,
                                    local_full_sig_path: str) -> str:
    # get database connection as conn
    # noinspection PyTypeChecker
    sql_query = sql.SQL("SELECT {full_path} FROM {table} WHERE deleted_at IS NULL AND "
                        "{condition} like %s").format(
        table=sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
        full_path = sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER']),
        condition=sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER'])
    )
    with local_conn.cursor() as cur:
        # use like operator '%' for wildcard search before and after
        cur.execute(sql_query, (f"%{local_full_sig_path}/%",))
        query_result = cur.fetchall()
        first_column = []
        dirname = ""

        if len(query_result) >= 1:
            for row in query_result:
                dirname = f"{Path(row[0].parent)}"
                without_ceph = row[0].replace(f"{local_env_variables['BASE_PATH_CEPH']}/", '')
                path_list = without_ceph.split('/')
                first_column.append(path_list[0])
            if len(set(first_column)) > 1:
                logging.error("First signature path is not identical! This means that there are some items secure and"
                              " some items not! This is not supported!")
                return ""
            return dirname
        else:
            # if we are here, then the tuple has more or less than one value and this is not ok
            logging.error("Something went wrong while getting full_sig_path count from sql")
            return ""

def get_delivery_from_database(local_conn: psycopg.Connection, local_env_variables: dict,
                               local_full_sig_path: str) -> str:
    # noinspection PyTypeChecker
    sql_query = sql.SQL("SELECT DISTINCT {delivery} FROM {table} WHERE deleted_at IS NULL AND "
                        "{condition} like %s").format(
        delivery = sql.Identifier(local_env_variables['DATABASE_TABLE_DELIVERY_IDENTIFIER']),
        table = sql.Identifier(local_env_variables['DATABASE_TABLE_NAME']),
        condition = sql.Identifier(local_env_variables['DATABASE_TABLE_ITEM_IDENTIFIER'])
    )
    with local_conn.cursor() as cur:
        # use like operator '%' for wildcard search before and after
        cur.execute(sql_query, (f"%{local_full_sig_path}/%",))
        query_result = cur.fetchall()
        if len(query_result) == 1 and len(query_result[0]) == 1:
            if len(query_result[0][0]) > 0:
                return query_result[0][0]
        else:
            # if we are here, then the tuple has more or less than one value and this is not ok
            logging.error("Something went wrong while getting full_sig_path count from sql")
            return ""
    return ""

def init() -> None:
    start = time.time()

    # read variables from env file
    global env_variables
    env_variables = read_env_variables_from_file()

    # init current date variable with today's date in format 2026-01-24
    global current_date
    current_date = date.today().strftime('%Y-%m-%d')
    # init logger without kitodo process id (not loaded at this moment)
    logging.basicConfig(level=logging.INFO, filename=f"{env_variables['KITODO_LOG_PATH']}/{current_date}_"
                                                     f"{get_script_name()}.log", encoding='utf8',
                        format='%(asctime)s - %(levelname)s - %(threadName)s: %(message)s')

    # get variables from command line arguments
    global cli_arguments
    cli_arguments = read_command_line_input_parameter(env_variables)

    # re init logger with kitodo process_id
    logging.basicConfig(level=logging.INFO, filename=f"{env_variables['KITODO_LOG_PATH']}/{current_date}_"
                                                     f"{get_script_name()}_{cli_arguments['kitodo_processid']}.log",
                        encoding='utf8', format='%(asctime)s - %(levelname)s - %(threadName)s: %(message)s', force=True)

    # add tty logger if stdin is tty
    if sys.stdin and sys.stdin.isatty():
        add_local_console_to_logger()

    set_correct_group_and_permission(f"{env_variables['KITODO_LOG_PATH']}/{current_date}_{get_script_name()}_"
                                     f"{cli_arguments['kitodo_processid']}.log", env_variables['CHOWN_GROUP'],
                                     int(env_variables['CHMOD_DEFAULT'], base=8))

    # setting default umask
    os.umask(int(env_variables['UMASK_DEFAULT']))

    # logging command line arguments
    logging.info(f"Given command line arguments: {json.dumps(cli_arguments, ensure_ascii=False)}")

    # define new variables from cli arguments and define some new variables with defaults
    global archive_sig, fond_sig, vze_sig
    archive_sig = cli_arguments['meta_archiveNameCUSTOM']
    fond_sig = cli_arguments['meta_stockUnitIDCUSTOM']
    vze_sig = cli_arguments['meta_unitIDCUSTOM']

    global vze_unknown, vze_multi, full_sig_path, vze_accessrestrict

    full_sig_path = f"{archive_sig}/{fond_sig}/{vze_sig}"

    match cli_arguments['meta_document_type']:
        case 'Unknown':
            vze_unknown = True
            full_sig_path = vze_sig
            vze_accessrestrict = False
        case 'Multimatch':
            vze_unknown = True
            vze_multi = True
            full_sig_path = vze_sig
            vze_accessrestrict = False

    if not is_access_restricted(cli_arguments):
        vze_accessrestrict = False

    logging.info(f"Protection status: {vze_accessrestrict}")
    end = time.time()
    logging.info(f"Init of library took {end - start} seconds")