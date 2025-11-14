#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script Name: split_x_detector.py
Version: 4.1
Owner: HLA
Licence: MIT

This script processes a directory containing PDF files and performs
the following steps in a RAM-safe and sequential manner:

This script automatically splits large PDF files into smaller ones 
based on pages that contain a visible 'X' separator mark.

Pdfs shoud be named in sequence like: hhstaw_519--3_nr_1.pdf, hhstaw_519--3_nr_375.pdf ...

Main Functions:
1. Detects separator pages containing an “X” mark using OpenCV templates.
2. Splits the large PDF into smaller PDFs — one split per Signatur block.
3. Extracts all pages of each small PDF into image files (JPG or TIFF only).
4. Performs *real image format conversion* (not only extension change).
5. Reads the *first page* of each block via OCR and extracts the signatur:
       Example: “Signatur: 519/3-00180”
       → signatur_number = 180
6. If OCR signatur fails, the signatur number is derived from the PDF filename.
        Example: “filename: hhstaw_519--3_nr_9.pdf”
       → signatur_number = 9,10,11.....
7. Each block is stored in:
       /media/cepheus/secure/<root>/<subfolder>/<signatur_number>/
8. Convert each split PDF’s pages to image files (jpg/tif depending on output).
9. Move extracted images into the same numbered folder.
10. Each small PDF is deleted after extraction.
11. Large PDF is deleted after all blocks are processed.
12. All actions and errors are logged into timestamps log files.

Usage:
    python3 split_x_detector.py /path/to/pdf_directory/
    
If the path argument o templates is missing or invalid, the script will log the error and exit.
"""

import os
import sys
import cv2
import gc
import re
import time
import numpy as np
from tqdm import tqdm
from datetime import datetime
from pdf2image import convert_from_path
from PyPDF2 import PdfReader, PdfWriter
from PIL import Image
import pytesseract

# ---------------- CONFIGURATION ----------------
TEMPLATE_DIR = "/media/cepheus/ingest/testcharts_bestandsblatt/x_templates/"
LOG_DIR = "logs"
THRESHOLD = 0.55          # template match threshold
SCALES = [0.5, 0.75, 1.0, 1.25]
OUTPUT_FORMAT = "jpg"     # allowed: jpg or tiff
# ------------------------------------------------

timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
LOG_FILE = os.path.join(LOG_DIR, f"process_{timestamp}.log")
ERROR_FILE = os.path.join(LOG_DIR, f"error_{timestamp}.log")
os.makedirs(LOG_DIR, exist_ok=True)

# ------------------------------------------------
# LOGGING HELPERS
# ------------------------------------------------
def log_message(msg):
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}\n")

def log_error(msg):
    with open(ERROR_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] ERROR: {msg}\n")

# ------------------------------------------------
# TEMPLATE MATCHING
# ------------------------------------------------
def detect_x(image, templates):
    """Returns True if an X-template is detected in the given image."""
    gray = cv2.cvtColor(np.array(image), cv2.COLOR_BGR2GRAY)

    for template in templates:
        temp_gray = cv2.cvtColor(template, cv2.COLOR_BGR2GRAY)

        for scale in SCALES:
            h = int(temp_gray.shape[0] * scale)
            w = int(temp_gray.shape[1] * scale)
            if h < 2 or w < 2:
                continue

            resized = cv2.resize(temp_gray, (w, h))

            # template larger than page region → skip
            if gray.shape[0] < h or gray.shape[1] < w:
                continue

            res = cv2.matchTemplate(gray, resized, cv2.TM_CCOEFF_NORMED)
            _, max_val, _, _ = cv2.minMaxLoc(res)

            if max_val >= THRESHOLD:
                return True

    return False

# ------------------------------------------------
# OCR SIGNATUR EXTRACTION
# ------------------------------------------------
def extract_signatur_from_image(img):
    """
    Extracts the signatur number from OCR text.
    Expected pattern:  'Signatur: 519/3-00180'
    Returned: 180
    """
    try:
        text = pytesseract.image_to_string(img, config='--psm 6')
        match = re.search(r"Signatur:\s*\d+/\d+-(\d+)", text)

        if match:
            return int(match.group(1).lstrip("0"))  # remove leading zeros
    except Exception as e:
        log_error(f"OCR failed: {e}")

    return None

def extract_signatur_from_filename(filename):
    """
    Example filename: hhstaw_519--3_nr_9.pdf
    → returns: 9
    """
    num = re.search(r"_nr_(\d+)", filename)
    if num:
        return int(num.group(1))
    return 1

# ------------------------------------------------
# OUTPUT FOLDER BUILDER
# ------------------------------------------------
def build_output_folder(base_name, signatur_number):
    """
    Build folder:
        /media/cepheus/secure/<root>/<subfolder>/<signatur_number>/
    Example base_name: hhstaw_519--3_nr_9
    """
    parts = base_name.split("_")
    
    try:
    root = parts[0]               # hhstaw
    subfolder = parts[1]          # 519--3
    except IndexError:
        raise ValueError(f"Unexpected filename pattern: {base_name}")

    folder = os.path.join("/media/cepheus/secure", root, subfolder, str(signatur_number))
    if os.path.exists(folder):
        folder += "_undefined"
    os.makedirs(folder, exist_ok=True)
    return folder

# ------------------------------------------------
# REAL IMAGE FORMAT CONVERSION
# ------------------------------------------------
def convert_image_properly(img, output_path, format_ext):
    """
    Ensures real conversion of the image to the desired format.
    format_ext: 'jpg' or 'tiff'
    """
    if format_ext.lower() == "jpg":
        img = img.convert("RGB")
        img.save(output_path, "JPEG", quality=95)
    else:
        img.save(output_path, "TIFF", compression="tiff_deflate")

# ------------------------------------------------
# MAIN PDF SPLITTER
# ------------------------------------------------
def split_pdf_on_x(pdf_path, templates):
    """Split large PDF to small PDFs safely to avoid overloading RAM."""
    base_name = os.path.splitext(os.path.basename(pdf_path))[0]
    reader = PdfReader(pdf_path)
    num_pages = len(reader.pages)

    log_message(f"Processing PDF {pdf_path} ({num_pages} pages)")

    x_positions = []

    # -------- STEP 1: SCAN PAGES FOR X-TEMPLATES --------------------
    for page in tqdm(range(1, num_pages + 1),
                     desc=f"Scanning {base_name}", unit="pg", dynamic_ncols=True):

        try:
            img = convert_from_path(pdf_path, first_page=page, last_page=page)[0]
            top_half = img.crop((0, 0, img.width, img.height // 2))

            if detect_x(top_half, templates):
                x_positions.append(page - 1)

            del img, top_half
            gc.collect()

        except Exception as e:
            log_error(f"Page {page} conversion failed: {e}")

    if not x_positions:
        x_positions = [0]

    # block ranges
    blocks = []
    for i, idx in enumerate(x_positions):
        start = idx
        end = x_positions[i+1] if i+1 < len(x_positions) else num_pages
        blocks.append((start, end))

    # -------------------------------------------------------------
    # STEP 2: PROCESS EACH BLOCK
    # -------------------------------------------------------------
    for block_id, (start, end) in enumerate(blocks, start=1):

        # make a small PDF
        writer = PdfWriter()
        for p in range(start, end):
            writer.add_page(reader.pages[p])

        small_pdf_name = f"{base_name}_block_{block_id}.pdf"
        small_pdf_path = os.path.join("/tmp", small_pdf_name)

        with open(small_pdf_path, "wb") as f:
            writer.write(f)

        # extract first page → OCR signatur
        img_first = convert_from_path(small_pdf_path, first_page=1, last_page=1)[0]
        ocr_signatur = extract_signatur_from_image(img_first)

        if ocr_signatur is None:
            ocr_signatur = extract_signatur_from_filename(base_name)

        output_folder = build_output_folder(base_name, ocr_signatur)

        # -------------------------------------------------------------
        # STEP 3: EXPORT EACH PAGE OF SMALL PDF AS PROPER IMAGES
        # -------------------------------------------------------------
        for p in range(1, len(writer.pages) + 1):
            try:
                img = convert_from_path(small_pdf_path, first_page=p, last_page=p)[0]

                out_name = f"{base_name}_sig_{ocr_signatur}_{p:04d}.{OUTPUT_FORMAT}"
                out_path = os.path.join(output_folder, out_name)

                convert_image_properly(img, out_path, OUTPUT_FORMAT)

                del img
                gc.collect()

            except Exception as e:
                log_error(f"Image export failed for block {block_id}, page {p}: {e}")

        # Delete the temporary small PDF after processing the images
        os.remove(small_pdf_path)
        log_message(f"Deleted temporary small PDF: {small_pdf_path}")

    # Delete the original large PDF after processing
    os.remove(pdf_path)
    log_message(f"Deleted original PDF: {pdf_path}")
    log_message(f"✔ Completed {base_name}\n")

# ------------------------------------------------
# MAIN ENTRY
# ------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 split_x_detector.py /path/to/pdf_directory/")
        sys.exit(1)

    input_dir = sys.argv[1]
    if not os.path.isdir(input_dir):
        log_error(f"Invalid directory: {input_dir}")
        sys.exit(1)

    # load templates
    templates = []
    for f in os.listdir(TEMPLATE_DIR):
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".tif", ".tiff", ".ppm")):
            img = cv2.imread(os.path.join(TEMPLATE_DIR, f))
            if img is not None:
                templates.append(img)

    if not templates:
        log_error("No template images found.")
        sys.exit(1)

    log_message("--- Script started ---")

    pdf_files = [f for f in os.listdir(input_dir) if f.lower().endswith(".pdf")]
    if not pdf_files:
        log_error("No PDF files found in directory.")
        sys.exit(1)

    print(f"Processing {len(pdf_files)} PDF(s)...")

    for pdf in pdf_files:
        split_pdf_on_x(os.path.join(input_dir, pdf), templates)

    print("✅ All PDFs processed successfully.")
    log_message("--- Script finished successfully ---\n")


if __name__ == "__main__":
    main()
