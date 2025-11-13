#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script Name: split_x_detector.py V:2.1

This script automatically splits large PDF files into smaller ones 
based on pages that contain a visible 'X' separator mark.

Pdfs shoud be named in sequence like: hhstaw_519--3_nr_1.pdf, hhstaw_519--3_nr_375.pdf ...

Main Functions:
1. Detect 'X' pages using OpenCV templates (multi-scale matching).
2. Split the input PDF into smaller PDFs between 'X' markers.
3. Automatically name each split: e.g. hhstaw_519--3_nr_1.pdf, hhstaw_519--3_nr_2.pdf ...
4. Create target folders: /media/cepheus/hhstaw/519--3/1/, /2/, /3/ ...
5. Convert each split PDF’s pages to image files (JPG/PNG/TIFF depending on output).
6. Move extracted images into the same numbered folder.
7. Delete the original PDF after successful processing.
8. Log all actions and errors to separate log files.

Usage:
    python3 split_x_detector.py /path/to/pdf_directory/

If the path argument is missing or invalid, the script will log the error and exit.
"""

import os
import sys
import cv2
import gc
import time
import numpy as np
from tqdm import tqdm
from datetime import datetime
from pdf2image import convert_from_path
from PyPDF2 import PdfReader, PdfWriter

# ---------------- CONFIGURATION ----------------
TEMPLATE_DIR = "/media/cepheus/ingest/testcharts_bestandsblatt/x_templates/"
LOG_DIR = "logs"
THRESHOLD = 0.5
SCALES = [0.5, 0.75, 1.0, 1.25]
# ------------------------------------------------

timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
LOG_FILE = os.path.join(LOG_DIR, f"process_{timestamp}.log")
ERROR_FILE = os.path.join(LOG_DIR, f"error_{timestamp}.log")

os.makedirs(LOG_DIR, exist_ok=True)

# ---------------- LOGGING HELPERS ----------------
def log_message(msg: str):
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}\n")

def log_error(msg: str):
    with open(ERROR_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] ERROR: {msg}\n")
# -------------------------------------------------


def detect_any_x_multiscale(image, templates, threshold=THRESHOLD, scales=SCALES):
    """Return True if any X template is detected in the image."""
    gray = cv2.cvtColor(np.array(image), cv2.COLOR_BGR2GRAY)
    for template in templates:
        t_gray = cv2.cvtColor(template, cv2.COLOR_BGR2GRAY)
        for scale in scales:
            w, h = int(t_gray.shape[1] * scale), int(t_gray.shape[0] * scale)
            if w < 2 or h < 2:
                continue
            resized = cv2.resize(t_gray, (w, h))
            if gray.shape[0] < h or gray.shape[1] < w:
                continue
            res = cv2.matchTemplate(gray, resized, cv2.TM_CCOEFF_NORMED)
            if cv2.minMaxLoc(res)[1] >= threshold:
                return True
    return False


def safe_convert_page(pdf_path, page_num):
    """Safely convert a single page from PDF to image."""
    return convert_from_path(pdf_path, first_page=page_num, last_page=page_num)[0]


def build_output_folder(base_name):
    """Build correct folder structure like hhstaw/509/1/ etc."""
    parts = base_name.split("_")
    try:
        root = parts[0]
        subfolder = parts[1]
        main_no = parts[2] if len(parts) > 2 else "1"
    except IndexError:
        raise ValueError(f"Unexpected filename pattern: {base_name}")

    folder_base = os.path.join("/media/cepheus", root, subfolder, main_no)
    if os.path.exists(folder_base):
        folder_base += "_undefined"
    os.makedirs(folder_base, exist_ok=True)
    return folder_base


def split_pdf_on_x(pdf_path, templates):
    """Split large PDF to small PDFs safely to avoid overloading RAM."""
    base_name = os.path.splitext(os.path.basename(pdf_path))[0]
    try:
        folder_base = build_output_folder(base_name)
        reader = PdfReader(pdf_path)
        num_pages = len(reader.pages)
        log_message(f"Processing {pdf_path} ({num_pages} pages).")

        x_indices = []
        pbar = tqdm(range(1, num_pages + 1), desc=f"Scanning {base_name}", unit="pg", dynamic_ncols=True)

        for i in pbar:
            try:
                img = safe_convert_page(pdf_path, i)
                roi = np.array(img)[0:int(img.height / 2), :]
                if detect_any_x_multiscale(roi, templates):
                    x_indices.append(i - 1)
                del img
                gc.collect()
            except Exception as e:
                log_error(f"Page {i} conversion failed: {e}")

        if not x_indices:
            x_indices = [0]

        blocks = []
        for j, idx in enumerate(x_indices):
            start = idx
            end = x_indices[j + 1] if j + 1 < len(x_indices) else num_pages
            blocks.append((start, end))

        for block_idx, (start, end) in enumerate(blocks, start=1):
            writer = PdfWriter()
            for p in range(start, end):
                writer.add_page(reader.pages[p])

            folder_out = os.path.join(folder_base, str(block_idx))
            os.makedirs(folder_out, exist_ok=True)

            pdf_out_name = f"{base_name.split('_nr_')[0]}_nr_{block_idx}.pdf"
            pdf_out_path = os.path.join(folder_out, pdf_out_name)

            with open(pdf_out_path, "wb") as f:
                writer.write(f)

            log_message(f"Saved split PDF: {pdf_out_path}")

            # Convert to image per page
            for page_num in range(1, len(writer.pages) + 1):
                try:
                    img = convert_from_path(pdf_out_path, first_page=page_num, last_page=page_num)[0]
                    fmt = getattr(img, "format", "JPEG") or "JPEG"
                    ext = fmt.lower() if fmt.lower() in ("jpeg", "jpg", "png", "tiff", "tif", "ppm") else "jpg"
                    temp_img_name = f"{base_name}_nr_{block_idx}_{page_num:04d}.{ext}"
                    # Read image
                    img = cv2.imread(temp_img_name)
                    # Convert and save
                    img_name = f"{base_name}_nr_{block_idx}_{page_num:04d}.tif"
                    cv2.imwrite(img_name, img)
                    img.save(os.path.join(folder_out, img_name), fmt.upper())
                    del img
                    gc.collect()
                except Exception as e:
                    log_error(f"Image export failed for page {page_num}: {e}")

        os.remove(pdf_path)
        log_message(f"Deleted original PDF: {pdf_path}")
        log_message(f"✅ {base_name} completed successfully.\n")

    except Exception as e:
        log_error(f"Failed to process {pdf_path}: {e}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 split_x_detector.py /path/to/pdf_directory/")
        sys.exit(1)

    input_dir = sys.argv[1]
    if not os.path.isdir(input_dir):
        log_error(f"Invalid directory: {input_dir}")
        sys.exit(1)

    templates = []
    for f in os.listdir(TEMPLATE_DIR):
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".tiff")):
            t = cv2.imread(os.path.join(TEMPLATE_DIR, f))
            if t is not None:
                templates.append(t)
    if not templates:
        log_error("No valid templates found.")
        sys.exit(1)

    log_message(f"--- Script started at {datetime.now():%Y-%m-%d %H:%M:%S} ---")
    log_message(f"Using template dir: {TEMPLATE_DIR}")

    pdf_files = [f for f in os.listdir(input_dir) if f.lower().endswith(".pdf")]
    if not pdf_files:
        log_error("No PDF files found in directory.")
        sys.exit(1)

    print(f"🔹 Processing {len(pdf_files)} PDF file(s)...")
    for file in pdf_files:
        split_pdf_on_x(os.path.join(input_dir, file), templates)

    print("✅ All PDFs processed successfully.")
    log_message("--- Script finished successfully ---\n")


if __name__ == "__main__":
    main()