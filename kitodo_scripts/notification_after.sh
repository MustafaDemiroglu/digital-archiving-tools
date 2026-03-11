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
TARGET_DIR="${kitodo_metadata_path}/${kitodo_processid}"
RENAME_FILE="${TARGET_DIR}/rename.txt"

if [[ ! -f "${RENAME_FILE}" ]]; then
    log_info "No rename.txt found. Process was not renamed. Nothing to do."
    exit 0
fi

log_info "rename.txt detected. Processing rename notification."

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

#MAIL_FROM="hla-repo@uni-marburg.de"

# 3- Read rename information
FIRST_LINE=$(sed -n '1p' "${RENAME_FILE}")
OLD_SIG=$(sed -n '3p' "${RENAME_FILE}" | sed 's/^OLD_FULL_SIG: //')
NEW_SIG=$(sed -n '4p' "${RENAME_FILE}" | sed 's/^NEW_FULL_SIG: //')

# 4- Build mail subject
SUBJECT="Projekt SiFi: Umbenennung - ${FIRST_LINE} in Lieferung ${meta_delivery} wurde erfolgreich durchgeführt."

# 5. Build mail body
MAIL_BODY=$(cat <<EOF
Liebe Kolleginnen und Kollegen,

im Rahmen des Projektes SiFi wurde nach einer Korrekturanfrage
folgende Umbenennung durchgeführt.

Betroffener Vorgang:
Alte Kitodo Processtitle: ${FIRST_LINE}
Neue Kitodo Processtitle: ${kitodo_processtitle}

Alte Signatur:
${OLD_SIG}

Neue Signatur:
${NEW_SIG}

Die Änderung wurde entsprechend der im Workflow angegebenen
Korrektur durchgeführt.

Falls Sie der Meinung sind, dass diese Änderung nicht korrekt ist
oder ein Fehler vorliegt, geben Sie uns bitte kurz Bescheid.

Wenn die Änderung korrekt ist, können Sie diese E-Mail
einfach ignorieren.

Vielen Dank für Ihre Unterstützung.

Viele Grüße
HlaDigiTeam

Achtung:
Dies ist eine automatisch generierte E-Mail. Bitte verwenden Sie diese E-Mail-Adresse nicht für Antworten.
Bei Fragen zu dieser E-Mail wenden Sie sich bitte an das HlaDigiTeam.
Mustafa.Demiroglu@hla.hessen.de
Sam.Krasser@hla.hessen.de
Nils.Reichert@hla.hessen.de
Andrea.Langner@hla.hessen.de
Corinna.Berg@hla.hessen.de
EOF
)

# 6. Send mail

log_info "Sending rename notification mail to ${MAIL_TO}"

echo "${MAIL_BODY}" | mail -s "${SUBJECT}" "${MAIL_TO}"

# 7. Delete rename.txt
log_info "Removing rename.txt"

rm -f "${RENAME_FILE}"

log_info "Notification after rename action finished successfully."

exit 0