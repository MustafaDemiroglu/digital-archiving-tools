#!/bin/bash
# see library for needed parameters

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIL_SCRIPT="${SCRIPT_DIR}/mailjob.py"

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


# 1-Determine archive house
HAUS=architekturzeichnung
log_info "Detected archive house: ${HAUS}"

# 2- Build mail subject
SUBJECT="Projekt Architektrzeichnung: Bearbeitung der Liste ${meta_delivery} wurde erfolgreich durchgeführt."

# 3. Build mail body
MAIL_BODY=$(cat <<EOF
Liebe Kolleginnen und Kollegen,

im Rahmen des Projektes Architekturzeichnungen wurde Liste ${meta_delivery} bearbeitet.

Bitte beachten Sie, dass nach Erhalt dieser E-Mail zunächst ein Wochenende abgewartet werden sollte, da die Aktualisierung in Arcinsys in diesem Zeitraum erfolgt. Erst danach sind die vorgenommenen Änderungen vollständig sichtbar.

Die Änderung wurde entsprechend der im Workflow angegebenen Korrekturliste durchgeführt.

Wir bitten Sie daher, die Inhalte erst anschließend zu prüfen. Sollten Ihnen dabei Fehler oder Unstimmigkeiten auffallen, zögern Sie bitte nicht, uns zu kontaktieren.

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
log_info "Sending rename notification mail via pyhton mailjob.py"
python3 "${MAIL_SCRIPT}" \
    --haus "${HAUS}" \
    --subject "${SUBJECT}" \
    --body "${MAIL_BODY}"

# 8- Exit
log_info "Notification for Architekturzeichnungen finished successfully."
exit 0