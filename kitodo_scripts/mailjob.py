import smtplib
from email.message import EmailMessage

msg = EmailMessage()
msg['Subject'] = "Test E-Mail"
msg['From'] = "hla-repo@uni-marburg.de"
msg['To'] = "Mustafa.Demiroglu@hla.hessen.de"
msg.set_content("""Hallo Mustafa,

Dies ist eine automatisch generierte E-Mail. Bitte verwenden Sie diese E-Mail-Adresse nicht für Antworten.
Bei Fragen zu dieser E-Mail wenden Sie sich bitte an das HlaDigiTeam.""")

smtp_server = "smtp.uni-marburg.de"
smtp_port = 25
use_tls = True

with smtplib.SMTP(smtp_server, smtp_port) as server:
    if use_tls:
        server.starttls()
    server.send_message(msg)

print("Mail fertig.")