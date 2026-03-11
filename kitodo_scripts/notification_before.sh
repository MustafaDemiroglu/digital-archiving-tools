#!/bin/bash
# see library for needed parameters

set -euo pipefail

# Source Kitodo library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

search_folder_vze

# Logging, can be deleted if no needed
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 1- Check if this workflow step is relevant 
log_info "Checking process status..."

# only handle unknown or multimatch
if [[ -n "${meta_document_type}" ]]; then
	# if document type exists use metadata
    if [[ "${vze_unknown}" != "true" && "${vze_multi}" != "true" ]]; then
        log_info "Process is not Unknown or Multimatch (document_type based). Nothing to do."
        exit 0
    fi
else
	# fallback if document type missing
    if [[ ! "${kitodo_processtitle}" =~ ^Unbekannt_ && ! "${kitodo_processtitle}" =~ ^Multimatch_ ]]; then
        log_info "Process is not Unknown or Multimatch (processtitel based). Nothing to do."
        exit 0
    fi
fi

# Fremdarchivalien detection
is_fremdarchivalien="false"

if [[ "${folder_path}" == *"/fremdarchivalien/"* ]]; then
    is_fremdarchivalien="true"
fi

# ignore fremdarchivalien
if [[ "${is_fremdarchivalien}" == "true" ]]; then
    log_info "Fremdarchivalien detected. Nothing to do."
    exit 0
fi

# 2-Determine archive house

HAUS=$(echo "${full_sig_path}" | cut -d'/' -f1)

log_info "Detected archive house: ${HAUS}"

case "${HAUS}" in
    hstam)
		MAIL_TO="Mustafa.Demiroglu@hla.hessen.de"
        #MAIL_TO="Sabine.Fees@hla.hessen.de"
        ;;
    hstad)
		MAIL_TO="Mustafa.Demiroglu@hla.hessen.de"
        #MAIL_TO="Lars.Zimmermann@hla.hessen.de"
        ;;
    hhstaw)
		MAIL_TO="Mustafa.Demiroglu@hla.hessen.de"
        #MAIL_TO="Anke.Stoesser@hla.hessen.de"
        ;;
    adjb)
		MAIL_TO="Mustafa.Demiroglu@hla.hessen.de"
        #MAIL_TO="Mario.Aschoff@hla.hessen.de"
        ;;
    *)
        log_warn "Unknown archive house: ${HAUS}"
        exit 0
        ;;
esac

MAIL_FROM="hla-repo@uni-marburg.de"

# 3- Build mail subject

if [[ "${vze_multi}" == "true" ]]; then
    MATCH_TYPE="Multimatch"
else
    MATCH_TYPE="Unbekannt"
fi

SUBJECT="Projekt SiFi: Nacharbeitung erforderlich – ${kitodo_processtitle} in Lieferung ${meta_delivery}"

# 4. Build mail body
MAIL_BODY=$(cat <<EOF
Liebe Kolleginnen und Kollegen,

im Rahmen des Projektes SiFi wurde in der Lieferung ${meta_delivery} ein Vorgang festgestellt,
bei dem eine Nacharbeitung erforderlich ist.

Betroffener Vorgang:
${kitodo_processtitle}

Der Workflow kann aktuell nicht automatisch fortgesetzt werden.

Bitte prüfen Sie den Vorgang im Kitodo-Webanwendung und nehmen Sie die notwendigen Korrekturen vor.

EOF
)

if [[ "${MATCH_TYPE}" == "Unbekannt" ]]; then

MAIL_BODY+=$(cat <<EOF

Problem:
Die gelieferte Signatur stimmt nicht mit den Daten in Arcinsys überein.

Mögliche Lösungen:

- Vergleich der Signatur zwischen Arcinsys und Digitalisaten
- Umbenennung in Arcinsys oder bei den Digitalisaten
- ggf. Ergänzung einer neuen Signatur in Arcinsys
- Aktualisierung der Metadaten mit der korrekten Arcinsys-ID

Falls eine Aktualisierung der Metadaten nicht möglich ist,
muss aber der Prozess-Titel trotzdem entsprechend angepasst werden.
Entfernen Sie bitte den Begriff "Unbekannt_" aus dem Prozess-Titel
und setzen Sie die Schutzfrist korrekt um den Veröffettlichung_Fehler
zu vermeiden.

Wenn eine Umbenennung der Digitalisate erforderlich ist,
bitte dies im Prozess-Titel vermerken (entfernen Sie bitte den Begriff 
"Unbekannt" aus dem Prozess-Titel und setzen Sie "Rename") und nach Möglichkeit
die Schutzfrist korrekt setzen.

EOF
)

else

MAIL_BODY+=$(cat <<EOF

Problem:
In Arcinsys existieren mehrere Signaturen mit identischem Namen.

Damit der Workflow korrekt fortgesetzt werden kann,
muss eindeutig festgelegt werden, mit welcher Arcinsys-ID
die Metadaten verknüpft werden sollen.

Bitte aktualisieren Sie die Metadaten mit der korrekten Arcinsys-ID.

Falls eine Metadatenaktualisierung nicht möglich ist, trotzdem
entfernen Sie bitte den Begriff "Multimatch_" aus dem Prozess-Titel
und setzen Sie die Schutzfrist korrekt.

EOF
)

fi

MAIL_BODY+=$(cat <<EOF


Bei Fragen oder falls Unterstützung benötigt wird,
können Sie sich jederzeit an uns wenden.

Nach der gespeicherte Korrektur können Sie den Workflow in Kitodo
zweimal hochsetzen oder uns kurz informieren.

Vielen Dank für Ihre Unterstützung.

Viele Grüße
HlaDigiTeam
EOF
)

# 5. Send mail

log_info "Sending notification mail to ${MAIL_TO}"

echo "${MAIL_BODY}" | mail \
    -s "${SUBJECT}" \
    -a "FROM: ${MAIL_FROM}" \
    "${MAIL_TO}"

# 6. Create rename.txt for Unknown processes

if [[ "${MATCH_TYPE}" == "Unbekannt" ]]; then

    TARGET_DIR="${kitodo_metadata_path}/${kitodo_processid}"
    RENAME_FILE="${TARGET_DIR}/rename.txt"

    log_info "Creating rename.txt for follow-up workflow"

    echo "${kitodo_processtitle}" > "${RENAME_FILE}"

fi

log_info "Notification before rename action finished successfully."

exit 0