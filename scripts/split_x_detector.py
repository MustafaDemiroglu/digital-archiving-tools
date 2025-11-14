#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script Name: split_x_detector.py
Version: 4.2
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
13. Progress can be watched.

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
def detect_x(pil_image, templates):
    """Returns True if an X-template is detected in the given PIL image."""
    try:
        arr = np.array(pil_image)  # PIL -> HxWxC (RGB)
        gray = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY)
    except Exception as e:
        log_error(f"Failed to convert PIL image to gray: {e}")
        return False

    for template in templates:
        # template is loaded by cv2 (BGR)
        try:
            temp_gray = cv2.cvtColor(template, cv2.COLOR_BGR2GRAY)
        except Exception:
            # if template already gray
            temp_gray = template if len(template.shape) == 2 else cv2.cvtColor(template, cv2.COLOR_BGR2GRAY)

        for scale in SCALES:
            h = int(temp_gray.shape[0] * scale)
            w = int(temp_gray.shape[1] * scale)
            if h < 2 or w < 2:
                continue

            try:
                resized = cv2.resize(temp_gray, (w, h))
            except Exception:
                continue

            # template larger than page region → skip
            if gray.shape[0] < h or gray.shape[1] < w:
                continue

            try:
                res = cv2.matchTemplate(gray, resized, cv2.TM_CCOEFF_NORMED)
                _, max_val, _, _ = cv2.minMaxLoc(res)
            except Exception:
                continue

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
        match = re.search(r"Signatur[:\s]*\d+/\d+[-\s]*(\d+)", text, re.IGNORECASE)
        if match:
            return int(match.group(1).lstrip("0") or "0")
    except Exception as e:
        log_error(f"OCR failed: {e}")

    return None

def extract_signatur_from_filename(filename):
    """
    Example filename: hhstaw_519--3_nr_9.pdf  -> returns: 9
    Fallback: try last integer in filename, else 1
    """
    num = re.search(r"_nr_(\d+)", filename, re.IGNORECASE)
    if num:
        return int(num.group(1))
    # fallback: last number in filename
    last = re.findall(r"(\d+)", filename)
    if last:
        return int(last[-1])
    return 1

# ------------------------------------------------
# OUTPUT FOLDER BUILDER
# ------------------------------------------------
def build_output_folder(base_name, signatur_number):
    """
    Build folder:
        /media/cepheus/secure/<root>/<subfolder>/<signatur_number>/
    Uses first two underscore-separated parts if possible; otherwise safe defaults.
    """
    # try to extract two parts using regex for robustness
    m = re.match(r"([^_]+)_([^_]+)", base_name)
    if m:
        root = m.group(1)
        subfolder = m.group(2)
    else:
        parts = base_name.split("_")
        root = parts[0] if len(parts) >= 1 else "unknown_root"
        subfolder = parts[1] if len(parts) >= 2 else "unknown_sub"

    folder = os.path.join("/media/cepheus/secure", root, subfolder, str(signatur_number))
    if os.path.exists(folder):
        folder = folder + "_undefined"
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
    try:
        if format_ext.lower() == "jpg":
            rgb = img.convert("RGB")
            rgb.save(output_path, "JPEG", quality=95)
        else:
            # use TIFF
            img.save(output_path, "TIFF", compression="tiff_deflate")
    except Exception as e:
        log_error(f"Failed to save image {output_path}: {e}")
        raise
        
# ------------------------------------------------
# MAIN PDF PROCESSOR (split by detected X pages)
# ------------------------------------------------
def split_pdf_on_x(pdf_path, templates):
    """Process a PDF: detect X pages, split logically into blocks and export images."""
    base_name = os.path.splitext(os.path.basename(pdf_path))[0]
    try:
        reader = PdfReader(pdf_path)
        num_pages = len(reader.pages)
    except Exception as e:
        log_error(f"Failed to open PDF {pdf_path}: {e}")
        return

    log_message(f"Processing PDF {pdf_path} ({num_pages} pages)")
    x_positions = []

    # -------- STEP 1: SCAN PAGES FOR X-TEMPLATES --------------------
    # show progress for scanning pages (progress level 2: large PDF)
    scan_iter = range(1, num_pages + 1)
    for page in tqdm(scan_iter, desc=f"Scan {base_name}", unit="pg", dynamic_ncols=True):
        try:
            img = convert_from_path(pdf_path, first_page=page, last_page=page, fmt="ppm")[0]
            top_half = img.crop((0, 0, img.width, img.height // 2))

            if detect_x(top_half, templates):
                # store 0-based page index where X found
                x_positions.append(page - 1)

            del img, top_half
            gc.collect()
        except Exception as e:
            log_error(f"Page {page} conversion failed in {base_name}: {e}")

    # if no separators found -> treat whole file as single block starting at 0
    if not x_positions:
        blocks = [(0, num_pages)]
    else:
        # ensure x_positions sorted & unique
        x_positions = sorted(set(x_positions))
        blocks = []
        for i, idx in enumerate(x_positions):
            start = idx
            end = x_positions[i + 1] if i + 1 < len(x_positions) else num_pages
            # safety checks
            if start < 0:
                start = 0
            if end > num_pages:
                end = num_pages
            if start >= end:
                continue
            blocks.append((start, end))

    # If still no blocks (edge case), create single block
    if not blocks:
        blocks = [(0, num_pages)]
    
    # if needen, signatur nr should be taken from filename 
    signatur_from_filename = extract_signatur_from_filename(base_name)

    # -------------------------------------------------------------
    # STEP 2: PROCESS EACH BLOCK (progress level 3: blocks and pages)
    # -------------------------------------------------------------
    for block_id, (start, end) in enumerate(tqdm(blocks, desc=f"Blocks {base_name}", unit="blk", dynamic_ncols=True), start=1):
        block_page_count = end - start
        if block_page_count <= 0:
            continue

        # Get first page image for OCR signatur
        first_page_num = start + 1  # convert_from_path expects 1-based page numbers
        ocr_signatur = None
        try:
            img_first = convert_from_path(pdf_path, first_page=first_page_num, last_page=first_page_num)[0]
            ocr_signatur = extract_signatur_from_image(img_first)
            del img_first
            gc.collect()
        except Exception as e:
            log_error(f"OCR first page conversion failed for block {block_id} in {base_name}: {e}")

        if ocr_signatur is None:
            ocr_signatur = signatur_from_filename
            signatur_from_filename = signatur_from_filename + 1
        output_folder = build_output_folder(base_name, ocr_signatur)

        # Export each page in block individually (progress bar per block)
        page_range = range(start + 1, end + 1)  # convert_from_path uses 1-based pages
        for p in tqdm(page_range, desc=f"{base_name} blk{block_id}", unit="pg", leave=False, dynamic_ncols=True):
            try:
                img = convert_from_path(pdf_path, first_page=p, last_page=p)[0]
                out_name = f"{base_name}_sig_{ocr_signatur}_{p-start:04d}.{OUTPUT_FORMAT}"
                out_path = os.path.join(output_folder, out_name)
                convert_image_properly(img, out_path, OUTPUT_FORMAT)
                del img
                gc.collect()
            except Exception as e:
                log_error(f"Image export failed for {base_name} block {block_id}, page {p}: {e}")

        log_message(f"Completed block {block_id} of {base_name} -> {output_folder}")

    # -------------------------------------------------------------
    # STEP 3: CLEANUP (delete original large PDF)
    # -------------------------------------------------------------
    try:
        os.remove(pdf_path)
        log_message(f"Deleted original PDF: {pdf_path}")
    except Exception as e:
        log_error(f"Failed to delete original PDF {pdf_path}: {e}")

    signatur_from_filename = 0
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
    if not os.path.isdir(TEMPLATE_DIR):
        log_error(f"Template directory does not exist: {TEMPLATE_DIR}")
        sys.exit(1)

    for f in os.listdir(TEMPLATE_DIR):
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".tif", ".tiff", ".ppm")):
            path = os.path.join(TEMPLATE_DIR, f)
            img = cv2.imread(path)
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

    # progress level 1: overall PDFs
    for pdf in tqdm(pdf_files, desc="All PDFs", unit="pdf", dynamic_ncols=True):
        pdf_path = os.path.join(input_dir, pdf)
        try:
            split_pdf_on_x(pdf_path, templates)
        except Exception as e:
            log_error(f"Unexpected error processing {pdf}: {e}")

    print("✅ All PDFs processed (or logged).")
    log_message("--- Script finished ---\n")

if __name__ == "__main__":
    main()