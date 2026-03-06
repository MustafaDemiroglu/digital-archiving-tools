#!/usr/bin/env python3
import argparse
import logging
import os
import shutil

import grp
import sys
import time
import yaml
# needs at least version 9.3.0 of PIL for LAB convertion
from PIL import Image
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

# Definition von Variabeln, die spaeter verwendet werden
help_strings = ["-h", "h", "--h", "-help", "help", "--help"]
logger = ""
formatter = ""

group: str
maxsize_x: int
maxsize_y: int
thumbnailsize: tuple[int, int]
original_maxsize_x = False
original_maxsize_y = False

errors_occurred = False

def load_config_file(config_file_path: str = "/etc/hla/generate_derivate.yml"):
    with open(config_file_path, encoding='utf8') as f:
        yaml_config = yaml.load(f.read(), Loader=yaml.Loader)
    local_profiles = yaml_config["profile"]
    return local_profiles


def overwrite_default_profile(profile: dict, default_profile: dict) -> dict:
    global errors_occurred
    custom_profile = dict(default_profile)
    for local_key in profile.keys():
        try:
            custom_profile[local_key] = profile[local_key]
        except KeyError:
            errors_occurred = True
            raise KeyError(f'{local_key} does not exist in default profile!')
    return custom_profile


# Erstellen und Initalisieren eines Loggers
def init_logger():
    local_logger = logging.getLogger()
    local_logger.setLevel(logging.DEBUG)
    return local_logger


# Erstellen eines Formatters um den Log zu formatieren
def init_formatter():
    local_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(threadName)s - %(processName)s - %(message)s')
    return local_formatter


# Funktion um Terminal Logger zu bekommen
def get_terminal_logger(local_formatter):
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    ch.setFormatter(local_formatter)
    return ch


# Funktion um Datei Logger mit der gewuenschten Datei zu bekommen
def get_file_logger(local_formatter, file):
    fh = logging.FileHandler(file)
    fh.setLevel(logging.INFO)
    fh.setFormatter(local_formatter)
    return fh

# Funktion fuer das Erzeugen des "Thumbnail" und das Schreiben der Dateien
def generate_write_image(local_image, local_image_type, local_size, local_quality, local_dpi, local_outfile_path,
                         local_exif_data, local_group, local_logger, log_message):
    local_image.thumbnail(local_size)
    local_logger.debug("Type of local_dpi variable: " + str(type(local_dpi)))
    if isinstance(local_dpi, tuple):
        local_image.save(local_outfile_path, exif=local_exif_data, quality=local_quality, dpi=local_dpi)
    else:
        local_image.save(local_outfile_path, exif=local_exif_data, quality=local_quality)

    try:
        shutil.chown(local_outfile_path, group=local_group)
    except Exception as e:
        local_logger.debug("Error while changing the group of the file")
        local_logger.debug(e)
    local_logger.info("successfully " +  log_message + local_image_type +
                      " convertion [resolution x,y: " +str(local_size) + " ]: " + local_outfile_path)

#def recursive_chown_folder(path, local_group, local_logger):
#    global errors_occurred
#    try:
#        local_logger.info("Starting correction of folder group permissions.")
#        for dirpath, dirnames, filenames in os.walk(path):
#            shutil.chown(dirpath, group=local_group)
#    except Exception as e:
#        errors_occurred = True
#        local_logger.error("cannot change group of folder: " + path)
#        local_logger.error(e)

def recursive_chown_folder(path, local_group, local_logger):
    global errors_occurred
    try:
        group_gid = grp.getgrnam(local_group).gr_gid
        try:
            local_logger.info("Starting correction of folder group permissions recursively.")
            for root, directories, files in os.walk(path):
                for directory in directories:
                    full_dir_path = os.path.join(root, directory)  #test to fix chown
                    stat_info = os.stat(full_dir_path)
                    current_gid = stat_info.st_gid
                    if current_gid == group_gid:
                        local_logger.debug(f"Group already correct for: {directory} (Group: {local_group})")
                        continue  # Keine Änderung nötig
                    shutil.chown(full_dir_path, group=local_group)  # test to fix chown 
                for file in files:
                    fname = os.path.join(root, file)
                    stat_info = os.stat(fname)
                    current_gid = stat_info.st_gid
                    if current_gid == group_gid:
                        local_logger.debug(f"Group already correct for: {fname} (Group: {local_group})")
                        continue  # Keine Änderung nötig
                    shutil.chown(fname, group=local_group)
        except Exception as e:
            errors_occurred = True
            local_logger.error("cannot change group of folder: " + path)
            local_logger.error(e)
    except KeyError:
        errors_occurred = True
        local_logger.error(f"Group '{local_group}' does not exist on the system.")
        return

# Funktion fur das Dateienkonvertieren
def convert_files(local_outbasefolder, local_datei, local_storage_path, local_logger, local_group):
    global errors_occurred
    log_message = ""

    # Deaktivieren der Ueberpruefung der Groesse der Bilddatei. siehe:
    # https://pillow.readthedocs.io/en/stable/releasenotes/5.0.0.html#decompression-bombs-now-raise-exceptions
    Image.MAX_IMAGE_PIXELS = None

    # Setze Dateinamen und Struktur der Eltern-Ordner zusammen
    infile = f'{str(Path(local_datei).parent)}/{Path(local_datei).name}'

    # Lege das Zielverzeichnis durch Austausch des Basisordners aus
    outdir = local_outbasefolder + str(Path(local_datei).parent).replace(local_storage_path, '')

    # Erstelle das Zielverzeichnis nebst übergeordneter Struktur
    Path(outdir).mkdir(parents=True, exist_ok=True)

    # Überprüfen, ob ein Datei-Prefix gesetzt ist
    output_file_prefix = str()
    if active_profile['output_file_prefix'] is not None:
        output_file_prefix = active_profile['output_file_prefix']

    # Erstelle thumbs-Ordner in alles Ausgabeordnern
    if active_profile['generate_thumbnails'] == "true":
        Path(outdir+'/'+active_profile['outbasefolder_thumb']).mkdir(exist_ok=True)

    if active_profile['generate_previews'] == "true":
        Path(outdir+'/'+active_profile['outbasefolder_preview']).mkdir(exist_ok=True)

    outfilename = Path(Path(local_datei).name).stem
    outfile_userimg = f'{outdir}/{output_file_prefix}{outfilename}.jpg'

    if active_profile['outbasefolder_max'] is not None:
        Path(outdir+'/'+active_profile['outbasefolder_max']).mkdir(exist_ok=True)
        outfile_userimg = f"{outdir}/{active_profile['outbasefolder_max']}/{output_file_prefix}{outfilename}.jpg"

    # Setze neuen Dateinamen auf neuen Ordnerbaum
    outfile_thumbs = f"{outdir}/{active_profile['outbasefolder_thumb']}/{output_file_prefix}{outfilename}.jpg"

    # Setzten des Preview Bild Pfades
    outfile_previews = f"{outdir}/{active_profile['outbasefolder_preview']}/preview.jpg"

    if infile is not outfile_userimg:
        try:
            im = Image.open(infile)
            exif_data = im.getexif()
            try:
                local_dpi = im.info['dpi']
                local_logger.debug("DPI value is: " + im.info['dpi'])
            except Exception as e:
                logger.debug("Error by getting DPI value. Setting to None")
                logger.debug(e)
                local_dpi = None
           # Löschen aller exif Daten
            exif_data.clear()

            if active_profile['dpi'] is not None:
                exif_data[282] = int(active_profile['dpi'])
                exif_data[283] = int(active_profile['dpi'])
                local_dpi = (int(active_profile['dpi']), int(active_profile['dpi']))

            # Ueberpruefen ob es sich um einen LAB (L*A*B*) Farbraum handelt
            # wenn ja entfernen / konvertieren
            if im.mode in "LAB":
                im = im.convert('RGB')
                log_message += "converted LAB color space to RGB, "

            # Ueberpruefen ob ein Alphachannel (Transparenz) in der Bilddatei vorhanden ist,
            # wenn ja entfernen / konvertieren
            if im.mode in ("RGBA", "P", "LA", "PA", "RGBa", "La"):
                im = im.convert('RGB')
                log_message += "converted to RGB, Removed alpha channel, "

            # Ueberpruefen ob es sich um 16Bit Schwarzweiss Bild handelt, wenn ja in 8Bit umwandeln
            if im.mode in ("I;16", "I;16B", "I;16L", "I;16N"):
                im = im.point(lambda local_i: local_i * (1. / 256)).convert('L')
                log_message += "converted 16bit to 8bit greyscale, "

            # Generieren und speichern der Bilddatei
            if active_profile['grayscale'] == "true":
                im = im.convert("L")

            if active_profile['generate_max'] == "true":
                # Überprüfen, ob Originalgröße verwendet werden soll (standardmäßig False)
                if (original_maxsize_x == True) and (original_maxsize_y == True):
                    local_maxsize = im.size
                    local_logger.debug("Using original size (x,y) as new size. " + str(local_maxsize))
                elif original_maxsize_x:
                    local_maxsize = (im.size[0], maxsize_y)
                    local_logger.debug("Using original value for x as new size. " + str(local_maxsize))
                elif original_maxsize_y:
                    local_maxsize = (maxsize_x, im.size[1])
                    local_logger.debug("Using original value for y as new size. " + str(local_maxsize))
                else:
                    local_maxsize = (maxsize_x, maxsize_y)
                    local_logger.debug("Using new size. " + str(local_maxsize))
                generate_write_image(im, "derivate", local_maxsize, int(active_profile['outquality']),
                                     local_dpi, outfile_userimg, exif_data, local_group, local_logger, log_message)

            # Generieren und speichern der Thumbnail Datei
            if active_profile['generate_thumbnails'] == "true":
                generate_write_image(im, "thumbnail", thumbnailsize, int(active_profile['outquality']),
                                     local_dpi, outfile_thumbs, exif_data, local_group, local_logger, log_message)

            # Generieren und speichern der Preview Datei
            if active_profile['generate_previews'] == "true":
                generate_write_image(im, "preview", previewsize, int(active_profile['outquality']),
                                     local_dpi, outfile_previews, exif_data, local_group, local_logger, log_message)

            # explizites schließen des geöffneten Images, damit der Image Core zerstört und der RAM
            # wieder freigegeben werden kann
            # https://pillow.readthedocs.io/en/stable/reference/Image.html#PIL.Image.Image.close
            im.close()

        except TypeError as e:
            errors_occurred = True
            local_logger.error("wrong parameter type. Check typed values!")
            local_logger.error("cannot convert: " + infile)
            local_logger.error(e)

        except Exception as e:
            errors_occurred = True
            local_logger.error("cannot convert: " + infile)
            local_logger.error(e)

    else:
        errors_occurred = True
        local_logger.error("name conflict")


def read_file_by_line(file_path):
    with open(file_path, mode='r', encoding='utf8', buffering=10 * 1024 * 1024) as file: # 10 MB buffer
        for file_line in file:
            yield file_line.rstrip()


if __name__ == "__main__":
    # explizites setzen der maximalen Anzahl von Blöcken, welche im RAM behalten werden sollen
    # (https://github.com/python-pillow/Pillow/issues/7935#issuecomment-2034626309)
    os.environ['PILLOW_BLOCKS_MAX'] = "10"
    # Laden des Konfigurationsfiles
    profiles = load_config_file()

    parser = argparse.ArgumentParser(description="Python3 Derivate Generierungsscript", epilog="Für genauere "
                                                                                               "Einstellungen / "
                                                                                               "Erklärungen siehe "
                                                                                               "/etc/hla"
                                                                                               "/generate_derivate.yml")
    parser.add_argument("--profile", "-p", type=str, required=False, default="default")
    for key in profiles["default"]:
        if type(profiles["default"][key]) is dict:
            for i in profiles["default"][key]:
                parser.add_argument(f"--{key}-{i}", required=False)
        else:
            parser.add_argument(f"--{key}", required=False)

    args = parser.parse_args()

    if args.profile not in profiles.keys():
        print(f'{args.profile} not in {profiles.keys()}')
        parser.print_help()
        sys.exit(2)
    active_profile = overwrite_default_profile(profiles[args.profile], profiles['default']) \
        if args.profile != "default" \
        else profiles['default']

    for key in profiles["default"]:
        if type(profiles["default"][key]) is dict:
            for i in profiles["default"][key]:
                tmp = getattr(args, f"{key}_{i}")
                if tmp is not None:
                    active_profile[key][i] = tmp
        else:
            tmp = getattr(args, key)
            if tmp is not None:
                active_profile[key] = tmp

    # Setzen der Standard umask
    os.umask(int(active_profile['umask']))

    # Setzen der Gruppenvariable
    group = active_profile['group']

    # Initialisieren des Loggers
    logger = init_logger()

    # Initialisieren des formatters fuer den Logger
    formatter = init_formatter()

    # load quality settings from profile settings and cast all integer values
    maxsize_x = int(active_profile['maxsize']['x'])
    maxsize_y = int(active_profile['maxsize']['y'])
    thumbnailsize = int(active_profile['thumbnailsize']['x']), int(active_profile['thumbnailsize']['y'])
    previewsize = int(active_profile['previewsize']['x']), int(active_profile['previewsize']['y'])

    # überprüfen, ob die Größe / Dimension des Originalbildes verwendet werden soll.
    # (Dies ist der Fall, wenn als x und y Wert jeweils 0 oder 1 übergeben wurde)
    if maxsize_x in  (0, 1):
        original_maxsize_x = True
    if maxsize_y in (0, 1):
        original_maxsize_y = True

    # check if verbose_output is true and setting terminal logger
    if active_profile['verbose_output'] == "true":
        logger.addHandler(get_terminal_logger(formatter))

    # check if log_file parameter ist not empty or not None and setting file_logger
    if active_profile['log_file'] != "" or active_profile['log_file'] is not None:
        logger.addHandler(get_file_logger(formatter, active_profile['log_file']))

    # define output folder
    outbasefolder = active_profile['outbasefolder'] + ('/' if active_profile['outbasefolder'][-1] != '/' else '')
    logger.info("output folder: "+outbasefolder)

    # check if storage_path is not empty or not None and setting storage_path
    if active_profile['storage_path'] != "" or active_profile['storage_path'] is not None:
        storage_path = active_profile['storage_path']
        logger.info("storage path to replace: "+storage_path)
    else:
        sys.exit("storage_path is empty but mandatory!")

    # Konvertiere alle Dateien mit n Threads gleichzeitig und Zeitmessung
    start = time.perf_counter()
    # Erstelle eine Liste von allen Dateien aus der Liste und ihren jeweiligen Eltern-Ordnern
    logger.info("input list: " + active_profile['generation_list'])

    if int(active_profile['max_threads']) > 1:
        image_executor = ProcessPoolExecutor(int(active_profile['max_threads']), )
        executor_queue = []
        for line in read_file_by_line(active_profile['generation_list']):
            executor_queue.append(image_executor.submit(convert_files,  outbasefolder, line, storage_path, logger,
                                                        group))

        image_executor.shutdown(wait=True)
    else:
        for line in read_file_by_line(active_profile['generation_list']):
            convert_files(outbasefolder, line, storage_path, logger, group)

    # Korrigieren / Setzen der Ordnerberechtigungen
    if active_profile['recursive_group_chown'] == "true":
        recursive_chown_folder(outbasefolder, group, logger)

    finish = time.perf_counter()

    logger.info(f'It took {finish-start} second(s) to finish.')

    if errors_occurred:
        sys.exit(1)
    else:
        sys.exit(0)
