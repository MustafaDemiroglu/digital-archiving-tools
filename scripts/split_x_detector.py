#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script Name: split_x_detector.py
Version: 5.5
Author: HlaDigiTeam
Licence: MIT
Description: This script automatically splits large PDF files into smaller ones 
based on pages that contain a visible 'X' separator mark.

This Script needs: python3 python3-pip poppler-utils tesseract-ocr opencv-python pdf2image pypdf2 pillow pytesseract tqdm numpy
sudo apt update
sudo apt install python3 python3-pip
pip install opencv-python pdf2image pypdf2 pillow pytesseract tqdm numpy
sudo apt install poppler-utils tesseract-ocr

This script processes a directory containing PDF files and performs
the following steps in a RAM-safe and sequential manner:

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
    
If the path argument or templates is missing or invalid, the script will log the error and exit.
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

# OUTPUT_FORMAT: allowed values (case-insensitive): "tif", "tiff", "jpg", "jpeg"
OUTPUT_FORMAT = "tif"

# TIFF / JPEG save options to control quality/size
# TIFF_COMPRESSION = None -> uncompressed TIFF (closest to original PPM size, lossless)
# Use "tiff_lzw" or "tiff_adobe_deflate" for lossless compression that reduces size but is still lossless.
TIFF_COMPRESSION = None   # None or "tiff_lzw" or "tiff_adobe_deflate"
TIFF_DPI = 300            # DPI to embed into saved image files

# JPEG settings (if using JPEG)
JPEG_QUALITY = 100
JPEG_SUBSAMPLING = 0      # 0 disables chroma subsampling (best quality)

# RENDER_DPI applied to pdf2image convert_from_path -> controls the pixel resolution of produced images
RENDER_DPI = 300

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
        if arr.ndim == 2:
            gray = arr
        else:
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

def extract_signatur_from_image(img):
    """
    Extracts ONLY a 5-digit signatur number (e.g. 00180 → 180).
    If no 5-digit block exists → returns None.
    """

    try:
        # ----------- OCR PREPROCESSING -----------
        try:
            import cv2
            np_img = np.array(img.convert("L"))

            np_img = cv2.equalizeHist(np_img)
            np_img = cv2.adaptiveThreshold(
                np_img, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                cv2.THRESH_BINARY, 31, 15
            )

            proc_img = Image.fromarray(np_img)
            raw_text = pytesseract.image_to_string(proc_img, config="--psm 1")

        except Exception:
            raw_text = pytesseract.image_to_string(img, config="--psm 11")

        if not raw_text:
            return None

        text = raw_text

        # ----------- BASIC NORMALIZATION -----------
        text = text.replace("—", "-").replace("–", "-")

        table = str.maketrans({
            "O": "0", "o": "0",
            "I": "1", "l": "1",
        })
        text = text.translate(table)

        text = re.sub(r"\s+", " ", text).strip()

        # ----------- FIND ALL 5-DIGIT NUMBERS -----------
        matches = re.findall(r"\b(\d{5})\b", text)

        if not matches:
            return None

        # take last (most reliable / actual signatur)
        num = matches[-1].lstrip("0") or "0"
        num = int(num)

        # sanity check limits
        if 1 <= num <= 99999:
            return num

        return None

    except Exception as e:
        log_error(f"OCR Signatur extraction failed: {e}")
        return None


"""
# ------------------------------------------------
# OCR SIGNATUR EXTRACTION
# ------------------------------------------------
def extract_signatur_from_image(img):
    """
    OCR extractor for 'Signatur: 519/3 – 00180' lines.
    Handles:
        - OCR errors (I→1, l→1, O→0, — → -)
        - Misread 'Signatur' variants
        - Noise around numbers
        - Hard fallbacks
    Returns: integer (e.g. 180) or None.
    """
    
    try:
        # ----------- OCR PREPROCESSING (noise reduction) -----------
        try:
            import cv2
            np_img = np.array(img.convert("L"))

            # increase contrast
            np_img = cv2.equalizeHist(np_img)

            # adaptive threshold (helps with old scans)
            np_img = cv2.adaptiveThreshold(
                np_img, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                cv2.THRESH_BINARY, 31, 15
            )

            proc_img = Image.fromarray(np_img)
            raw_text = pytesseract.image_to_string(proc_img, config="--psm 1")

        except Exception:
            # fallback: raw OCR
            raw_text = pytesseract.image_to_string(img, config="--psm 11")

        if not raw_text:
            return None

        text = raw_text

        # ----------- NORMALIZATION -----------
        # universal dash normalization
        text = text.replace("—", "-").replace("–", "-").replace("-", "-")

        # typical OCR confusions
        table = str.maketrans({
            "O": "0", "o": "0",
            "|": "/",
            "I": "1", "l": "1",
            "“": "", "”": "", '"': "",
        })
        text = text.translate(table)

        # remove hidden unicode noise
        text = re.sub(r"[\u200b\u200c\u200d]", "", text)

        # collapse whitespace
        text = re.sub(r"\s+", " ", text).strip()

        # normalize broken slash patterns
        text = re.sub(r"(\d)\s*[/]\s*(\d)", r"\1/\2", text)

        # normalize broken dash patterns:
        text = re.sub(r"(\d)\s*-\s*(\d{2,6})", r"\1-\2", text)


        # ----------- SIGNATUR LINE ISOLATION -----------
        # catch lines that contain "Signatur" in any broken OCR form
        signatur_line = None
        for line in text.split("\n"):
            if re.search(r"S[i1l]gnat[ur]+", line, re.IGNORECASE):
                signatur_line = line.strip()
                break

        if not signatur_line:
            return None


        # ----------- STEP 4 – cleanup line -----------
        line = signatur_line

        # Fix common OCR distortions:
        # e.g. "Slgnatur", "Sıgnatur", "Signatnr"
        line = re.sub(r"S[i1l]gnat[ur]+", "Signatur", line, flags=re.IGNORECASE)

        # final whitespace collapse
        line = re.sub(r"\s+", " ", line)


        # ----------- STEP 5 – PRIMARY PATTERN -----------
        patterns = [
            r"Signatur[: ]*\d+/\d+-?0*([0-9]{1,6})",     # clean pattern
            r"Signatur[: ]*\d+/\d+\s+([0-9]{1,6})",      # space instead of dash
            r"Signatur[: ]*\d+[/ ]\d+[- ]+0*([0-9]{1,6})", # messy separators
        ]

        for p in patterns:
            m = re.search(p, line, re.IGNORECASE)
            if m:
                num = m.group(1).lstrip("0")
                if num == "":
                    num = "0"
                num = int(num)

                # sanity check: archive signatur cannot be 0 or > 99999
                if 1 <= num <= 99999:
                    return num

        # ----------- STEP 6 – Fallback to extracting numbers directly -----------
        # If pattern fails, fallback to direct number search (5 digits, 00154 format, etc.)
        fallback = re.findall(r"\b(\d{5})\b", line)  # Look for 5 digit numbers
        if fallback:
            # If there is a valid fallback number, return it
            num = fallback[-1].lstrip("0") or "0"
            num = int(num)
            if 1 <= num <= 99999:
                return num

        return None

    except Exception as e:
        log_error(f"OCR Signatur extraction failed: {e}")
        return None
"""

def extract_signatur_counter(filename):
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
    """
    
    # /media/cepheus/ingest/hdd_upload/devisenakten/secure/hhstaw/519--3/<signatur_number>/
    folder = os.path.join("/media/cepheus/ingest/hdd_upload/devisenakten/secure/hhstaw/519--3", str(signatur_number))
    i = 0
    while os.path.exists(folder):
        i += 1
        folder = folder + "_match_" + str(i)
    os.makedirs(folder, exist_ok=True)
    return folder

# ------------------------------------------------
# REAL IMAGE FORMAT CONVERSION
# ------------------------------------------------
def convert_image_properly(img, output_path, format_ext):
    """
    Ensures real conversion of the image to the desired format.
    format_ext: 'jpg'/'jpeg' or 'tif'/'tiff'
    - For TIFF: by default saves UNCOMPRESSED if TIFF_COMPRESSION is None (closest to PPM raw size).
    - For JPEG: saves with highest quality and no chroma subsampling.
    - Embeds DPI metadata.
    """
    try:
        ext = format_ext.lower()
        # Normalize ext values
        if ext == "tiff":
            ext = "tif"
        if ext == "jpeg":
            ext = "jpg"

        if ext in ("jpg",):
            rgb = img.convert("RGB")
            save_kwargs = {"quality": JPEG_QUALITY, "subsampling": JPEG_SUBSAMPLING, "dpi": (TIFF_DPI, TIFF_DPI)}
            rgb.save(output_path, "JPEG", **save_kwargs)
            return

        # TIFF branch
        # Preserve grayscale 'L' where possible; otherwise convert to RGB.
        mode = img.mode
        if mode == "L":
            save_img = img
        elif mode == "RGB":
            save_img = img
        elif mode == "P":
            save_img = img.convert("RGB")
        elif mode == "CMYK":
            save_img = img.convert("RGB")
        elif mode == "RGBA":
            try:
                bg = Image.new("RGB", img.size, (255, 255, 255))
                alpha = img.split()[3]
                bg.paste(img, mask=alpha)
                save_img = bg
            except Exception:
                save_img = img.convert("RGB")
        else:
            save_img = img.convert("RGB")

        save_kwargs = {"dpi": (TIFF_DPI, TIFF_DPI)}
        if TIFF_COMPRESSION:
            save_kwargs["compression"] = TIFF_COMPRESSION
        # If TIFF_COMPRESSION is None, we intentionally do not add the compression kwarg (uncompressed TIFF)

        try:
            save_img.save(output_path, "TIFF", **save_kwargs)
        except Exception:
            # fallback: try without kwargs
            try:
                save_img.save(output_path, "TIFF")
            except Exception as e:
                log_error(f"Failed to save TIFF {output_path}: {e}")
                raise

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
    
    # if needed, signatur nr should be taken from filename 
    signatur_counter = extract_signatur_counter(base_name)

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
            signatur = signatur_counter
        else:
            signatur = ocr_signatur
        
        output_folder = build_output_folder(base_name, signatur)
        signatur_counter += 1

        # Export each page in block individually (progress bar per block)
        page_range = range(start + 1, end + 1)  # convert_from_path uses 1-based pages
        for p in tqdm(page_range, desc=f"{base_name} blk{block_id}", unit="pg", leave=False, dynamic_ncols=True):
            try:
                img = convert_from_path(pdf_path, first_page=p, last_page=p, dpi=RENDER_DPI, fmt="ppm")[0]
                # To name the images
                # path_parts = base_name.split("_")
                # root_haus = path_parts[0] if len(path_parts) >= 1 else "unknown_haus"
                # subfolder_bestand = path_parts[1] if len(path_parts) >= 2 else "unknown_bestand"
                
                root_haus = hhstaw
                subfolder_bestand = str(519--3)
                
                # normalize extension
                out_ext = OUTPUT_FORMAT.lower()
                if out_ext == "tiff":
                    out_ext = "tif"
                if out_ext == "jpeg":
                    out_ext = "jpg"


                out_name = f"{root_haus}_{subfolder_bestand}_nr_{signatur}_{p-start:04d}.{out_ext}"
                out_path = os.path.join(output_folder, out_name)

                convert_image_properly(img, out_path, out_ext)
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

    log_message(f"✔ Completed {base_name}\n")

# ------------------------------------------------
# MAIN ENTRY
# ------------------------------------------------
def main():
    print("Script has started. First checks the paths and templates")

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
    print("Checks are successfully completed. Processing started.")

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