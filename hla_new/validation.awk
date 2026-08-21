#!/usr/bin/awk -f
# einfaches ueberpruefungsscript
# JB, MG

BEGIN {
    # definieren des Counters
    count = 0
    # Setzen des Field Seperator auf zwei Leerzeichen (md5 checksum seperator)
    FS = "  "
    # definieren der erlaubten Zeichen im Dateipfad (Benennungsrichtlinie HLA)
    base_allowed_chars = "-abcdefghijklmnopqrstuvwxyz0-9_."
    allowed_chars_default = "[" base_allowed_chars "/]*"
    allowed_chars_hla = "[" base_allowed_chars "]*"
    # definieren des Pfades anhand der Benennungsrichtlinie,
    # es muessen immer genau drei Ordnertiefen vorkommen (NICHT bei Fremdarchivalien?)
    allow_folder_path_hla = "(secure/)?(hstam|hstad|hhstaw|adjb)"
    allowed_path_filename = allow_folder_path_hla "(/" allowed_chars_hla "){3}"
    # definieren der erlaubten Dateiendungen
    allowed_filetype = "\\." allowed_filetype_input_regex
    # Definieren des Anfang und Ende der Zeile
    hla_pattern = "^" allowed_path_filename allowed_filetype "$"
    default_pattern = "^" allowed_chars_default allowed_filetype "$"
}

{
    # ueberpruefen ob eine exclude_regex Variabel definiert wurde und wenn ja diese Zeilen ausschließen
    if (exclude_regex == "" || $2 !~ exclude_regex) {
        # ueberpruefen ob es sich um einen "hla" ordner handelt und wenn nein eine andere "weniger starke"
        # Regel benutzen als pattern check
        if ($2 ~ "^" allow_folder_path_hla) {
            pattern = hla_pattern
        } else {
            pattern = default_pattern
        }
        # ueberpruefen ob das oben definierte Pattern NICHT zutrifft
        if ($2 !~ pattern) {
            # Ausgabe des Dateinamens, der Zeilennummer in der Datei und den Dateipfad (zweite Spalte)
            print FILENAME ":" FNR ":" $2
            count ++
        }
    }
}

END {
    # Setze den Exit-Code des awk-Programms
    # Wenn count 0 ist, ist der Exit-Code 0 (Erfolg).
    # Wenn count > 0, ist der Exit-Code 1 (Problem).
    if (count > 0) {
        exit(1) # Signalisiert, dass Zeilen gefunden wurden
    } else {
        exit(0) # Signalisiert, dass keine Zeilen gefunden wurden
    }
}
