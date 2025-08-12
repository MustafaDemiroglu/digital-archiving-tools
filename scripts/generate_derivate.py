#!/usr/bin/env python3                                                                   
import argparse                                                                          
import logging                                                                           
import os                                                                                
import shutil                                                                            
                                                                                         
import sys                                                                               
import time                                                                              
import yaml                                                                              
# needs at least version 9.3.0 of PIL for LAB convertion                                 
from PIL import Image                                                                    
from concurrent.futures import ThreadPoolExecutor                                        
from pathlib import Path                                                                 
                                                                                         
# Definition von Variabeln, die spaeter verwendet werden                                 
help_strings = ["-h", "h", "--h", "-help", "help", "--help"]                             
logger = ""                                                                              
formatter = ""                                                                           
dateien = []                                                                             
                                                                                         
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
    local_logger.setLevel(logging.INFO)                                                  
    return local_logger                                                       


# Erstellen eines Formatters um den Log zu formatieren                                                                                                 
def init_formatter():                                                                                                                                  
    local_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')                                                                   
    return local_formatter                                                                                                                             
                                                                                                                                                       
                                                                                                                                                       
# Funktion um Terminal Logger zu bekommen                                                                                                              
def get_terminal_logger(local_formatter):                                                                                                              
    ch = logging.StreamHandler()                                                                                                                       
    ch.setLevel(logging.INFO)                                                                                                                          
    ch.setFormatter(local_formatter)                                                                                                                   
    return ch                                                                                                                                          
                                                                                                                                                       
                                                                                                                                                       
# Funktion um Datei Logger mit der gewuenschten Datei zu bekommen                                                                                      
def get_file_logger(local_formatter, file):                                                                                                            
    fh = logging.FileHandler(file)                                                                                                                     
    fh.setLevel(logging.INFO)                                                                                                                          
    fh.setFormatter(local_formatter)                                                                                                                   
    return fh                                                                                                                                          
                                                                                                                                                       
                                                                                                                                                       
# Funktion zum Erstellen der Eingabedateiliste (Aus einer Datei)                                                                                       
def generate_input_source_list(file, local_logger):                                                                                                    
                                                                                                                                                       
    with open(file, encoding='utf8') as f:                                                                                                             
        filelist = f.read().splitlines()                                                                                                               
                                                                                                                                                       
    # filtert leere Einträge aus Liste                                                                                                                 
    filelist = filter(lambda x: x != "", filelist)                                                                                                     
                                                                                                                                                       
    # Erstelle eine Liste von allen Dateien aus der Liste und ihren jeweiligen Eltern-Ordnnern                                                         
    local_logger.info("input list: " + file)                                                                                                           
                                                                                                                                                       
    return [(Path(local_i).name, str(Path(local_i).parent)) for local_i in filelist]                                                                   
                                                                                                                                                       
# Funktion fuer das Erzeugen des "Thumbnail" und das Schreiben der Dateien                                                                             
def generate_write_image(local_image, local_image_type, local_size, local_quality, local_outfile_path, local_exif_data, local_group, local_logger):    
    local_image.thumbnail(local_size)                                                                                                                  
    local_image.save(local_outfile_path, exif=local_exif_data, quality=local_quality)                                                                  
    shutil.chown(local_outfile_path, group=local_group)                                                                                                
    local_logger.info("successfully " + local_image_type + " convertion: " + local_outfile_path)                                                       
                                                                                                                                                       
def recursive_chown_folder(path, local_group, local_logger):                                                                                           
    global errors_occurred                                                                                                                             
    try:                                                                                                                                               
        for dirpath, dirnames, filenames in os.walk(path):                                                                                             
            shutil.chown(dirpath, group=local_group)                                                                                                   
    except Exception as e:                                                                                                                             
        errors_occurred = True                                                                                                                         
        local_logger.error("cannot change group of folder: " + path)                                                                                   
        local_logger.error(e)       

# Funktion fur das Dateienkonvertieren
def convert_files(entry_index, local_outbasefolder, local_dateien, local_storage_path, local_logger, local_group):
    global errors_occurred

    # Deaktivieren der Ueberpruefung der Groesse der Bilddatei. siehe:
    # https://pillow.readthedocs.io/en/stable/releasenotes/5.0.0.html#decompression-bombs-now-raise-exceptions
    Image.MAX_IMAGE_PIXELS = None

    # Setze Dateinamen und Struktur der Eltern-Ordner zusammen
    infile = f'{local_dateien[entry_index][1]}/{local_dateien[entry_index][0]}'

    # Lege das Zielverzeichnis durch Austausch des Basisordners aus
    outdir = local_outbasefolder + local_dateien[entry_index][1].replace(local_storage_path, '')

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

    outfilename = Path(local_dateien[entry_index][0]).stem
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
            # Löschen aller exif Daten
            exif_data.clear()

            if active_profile['dpi'] is not None:
                exif_data[282] = int(active_profile['dpi'])
                exif_data[283] = int(active_profile['dpi'])

            # Ueberpruefen ob es sich um einen LAB (L*A*B*) Farbraum handelt
            # wenn ja entfernen / konvertieren
            if im.mode in "LAB":
                im = im.convert('RGB')
                local_logger.info("success: converted LAB color space to RGB")


            # Ueberpruefen ob ein Alphachannel (Transparenz) in der Bilddatei vorhanden ist,
            # wenn ja entfernen / konvertieren
            if im.mode in ("RGBA", "P", "LA", "PA", "RGBa", "La"):
                im = im.convert('RGB')
                local_logger.info("success: converted to RGB, Removed alpha channel")

            # Ueberpruefen ob es sich um 16Bit Schwarzweiss Bild handelt, wenn ja in 8Bit umwandeln
            if im.mode in ("I;16", "I;16B", "I;16L", "I;16N"):
                im = im.point(lambda local_i: local_i * (1. / 256)).convert('L')
                local_logger.info("success: converted 16bit to 8bit greyscale")

            # Generieren und speichern der Bilddatei
            if active_profile['grayscale'] == "true":
                im = im.convert("L")

            if active_profile['generate_max'] == "true":
                # Überprüfen, ob Originalgröße verwendet werden soll (standardmäßig False)
                if (original_maxsize_x == True) and (original_maxsize_y == True):
                    local_maxsize = im.size
                    local_logger.info("Using original size (x,y) as new size. " + str(local_maxsize))
                elif original_maxsize_x:
                    local_maxsize = (im.size[0], maxsize_y)
                    local_logger.info("Using original value for x as new size. " + str(local_maxsize))
                elif original_maxsize_y:
                    local_maxsize = (maxsize_x, im.size[1])
                    local_logger.info("Using original value for y as new size. " + str(local_maxsize))
                else:
                    local_maxsize = (maxsize_x, maxsize_y)
                    local_logger.info("Using new size. " + str(local_maxsize))
                generate_write_image(im, "derivate", local_maxsize, int(active_profile['outquality']), outfile_userimg, exif_data, local_group, local_logger)

            # Generieren und speichern der Thumbnail Datei
            if active_profile['generate_thumbnails'] == "true":
                generate_write_image(im, "thumbnail", thumbnailsize, int(active_profile['outquality']), outfile_thumbs, exif_data, local_group, local_logger)

            # Generieren und speichern der Preview Datei
            if active_profile['generate_previews'] == "true":
                generate_write_image(im, "preview", previewsize, int(active_profile['outquality']), outfile_previews, exif_data, local_group, local_logger)

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

                                                                                                          
if __name__ == "__main__":                                                                                
    # Laden des Konfigurationsfiles                                                                       
    profiles = load_config_file()                                                                         
                                                                                                          
    parser = argparse.ArgumentParser(description="Python3 Derivate Generierungsscript", epilog="Für genauere "
                                                                                               "Einstellungen/ " 
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
                                                                                                          
    # Initalisieren des Loggers                                                                           
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

    # define list of files
    dateien = generate_input_source_list(active_profile['generation_list'], logger)

    # define output folder
    outbasefolder = active_profile['outbasefolder'] + ('/' if active_profile['outbasefolder'][-1] != '/' else '')
    logger.info("output folder: "+outbasefolder)

    # check if storage_path is not empty or not None and setting storage_path
    if active_profile['storage_path'] != "" or active_profile['storage_path'] is not None:
        storage_path = active_profile['storage_path']
        logger.info("storage path to replace: "+storage_path)
    else:
        sys.exit("storage_path is empty but mandatory!")

    # Konvertiere alle Dateien mit 4 Threads gleichzeitig und Zeitmessung
    start = time.perf_counter()
    with ThreadPoolExecutor(int(active_profile['max_threads'])) as executor:
        for i in range(0, len(dateien)):
            executor.submit(convert_files, i, outbasefolder, dateien, storage_path, logger, group)

    # Korrigieren / Setzen der Ordnerberechtigungen
    recursive_chown_folder(outbasefolder, group, logger)

    finish = time.perf_counter()

    logger.info(f'It took {finish-start} second(s) to finish.')

    if errors_occurred:
        sys.exit(1)
    else:
        sys.exit(0)