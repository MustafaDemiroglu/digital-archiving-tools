#!/usr/bin/env python3

import argparse
import smtplib
import sys
from email.message import EmailMessage

# Global Mail Configuration
SMTP_SERVER = "smtp.uni-marburg.de"
SMTP_PORT = 25
USE_TLS = True
MAIL_FROM = "hla-repo@uni-marburg.de"

# CC recipients
CC_RECIPIENTS = [
    "Mustafa.Demiroglu@hla.hessen.de",
    "Sam.Krasser@hla.hessen.de",
    "Nils.Reichert@hla.hessen.de",
    "Corinna.Berg@hla.hessen.de",
    "Andrea.Langner@hla.hessen.de"
]

# HAUS → Mail Mapping
HAUS_MAIL_MAP = {
    "hstam": "Sabine.Fees@hla.hessen.de",
    "hstad": "Lars.Zimmermann@hla.hessen.de",
    "hhstaw": "Anke.Stoesser@hla.hessen.de",
    "adjb": "Mario.Aschoff@hla.hessen.de"
}

# Resolve mail recipient based on HAUS
def get_recipient_for_haus(haus):
    haus = haus.lower()
    if haus not in HAUS_MAIL_MAP:
        raise ValueError(f"Unknown HAUS: {haus}")
    return HAUS_MAIL_MAP[haus]
   
# Send Mail   
def send_mail(haus, subject, body):
    try:
        mail_to = get_recipient_for_haus(haus)
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = MAIL_FROM
    msg["To"] = mail_to
    msg["Cc"] = ", ".join(CC_RECIPIENTS)
    msg.set_content(body)
    all_recipients = [mail_to] + CC_RECIPIENTS
    
    try:
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=30) as server:
            if USE_TLS:
                server.starttls()
            server.send_message(msg, from_addr=MAIL_FROM, to_addrs=all_recipients)
        print(f"[INFO] Mail successfully sent to {mail_to}")
    except Exception as e:
        print(f"[ERROR] Mail sending failed: {e}", file=sys.stderr)
        sys.exit(1)

# Main
def main():
    parser = argparse.ArgumentParser(description="Generic Kitodo Mail Sender")
    parser.add_argument("--haus", required=True, help="Archive house (hstam, hstad, hhstaw, adjb)")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--body", required=True)
    args = parser.parse_args()

    send_mail(
        args.haus,
        args.subject,
        args.body
    )

if __name__ == "__main__":
    main()