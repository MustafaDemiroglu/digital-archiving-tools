#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
This script automatically splits large PDF files into smaller ones 
based on pages that contain a visible 'X' separator mark.

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

import cv2
import os
import sys
import numpy as np
from datetime import datetime
from pdf2image import convert_from_path
from PyPDF2 import PdfReader, PdfWriter

# ----- CONFIGURATION -----
TEMPLATE_DIR = "/media/cepheus/ingest/testcharts_bestandsblatt/x_templates/"
LOG_FILE = "process.log"
ERROR_FILE = "error.log"
THRESHOLD = 0.5
SCALES = [0.5, 0.75, 1.0, 1.25, 1.5]
# --------------------------

def log_message(message: str):
    """Write log messages to process.log with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] {message}\n")
    print(message)

def log_error(error_message: str):
    """Write errors to error.log with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(ERROR_FILE, "a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] ERROR: {error_message}\n")
    print(f"❌ {error_message}")

def detect_any_x_multiscale(image, templates, threshold=THRESHOLD, scales=SCALES):
    """Detect if any of the provided templates match an 'X' mark on the image."""
    gray_image = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    for template in templates:
        t_gray = cv2.cvtColor(template, cv2.COLOR_BGR2GRAY)
        for scale in scales:
            w, h = int(t_gray.shape[1] * scale), int(t_gray.shape[0] * scale)
            if w < 1 or h < 1:
                continue
            resized = cv2.resize(t_gray, (w, h))
            if gray_image.shape[0] < h or gray_image.shape[1] < w:
                continue
            result = cv2.matchTemplate(gray_image, resized, cv2.TM_CCOEFF_NORMED)
            _, max_val, _, _ = cv2.minMaxLoc(result)
            if max_val >= threshold:
                return True
    return False

def split_pdf_on_x(pdf_path, templates):
    """Split a PDF into smaller ones based on detected 'X' marks."""
    try:
        base_name = os.path.basename(pdf_path)
        base_no_ext = os.path.splitext(base_name)[0]

        # Example: hhstaw_519--3_nr_1.pdf -> hhstaw/519--3/
        parts = base_no_ext.split("_nr_")[0]
        folder_base = os.path.join("/media/cepheus", parts.replace("_", "/"))

        images = convert_from_path(pdf_path)
        reader = PdfReader(pdf_path)
        num_pages = len(images)
        log_message(f"Processing {pdf_path} ({num_pages} pages).")

        x_indices = []
        for i, img in enumerate(images):
            img_np = np.array(img)
            roi = img_np[0:img_np.shape[0] // 2, :]
            if detect_any_x_multiscale(roi, templates):
                log_message(f"X detected on page {i+1}")
                x_indices.append(i)
            else:
                log_message(f"No X on page {i+1}")

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

            pdf_out_name = f"{base_no_ext.split('_nr_')[0]}_nr_{block_idx}.pdf"
            pdf_out_path = os.path.join(folder_out, pdf_out_name)

            with open(pdf_out_path, "wb") as f:
                writer.write(f)
            log_message(f"Saved split PDF: {pdf_out_path}")

            # Convert each split PDF to images
            try:
                pages = convert_from_path(pdf_out_path)
                for i, page in enumerate(pages, start=1):
                    # Determine image format dynamically
                    fmt = page.format if hasattr(page, 'format') else "JPEG"
                    fmt = fmt if fmt else "JPEG"

                    img_ext = fmt.lower() if fmt.lower().startswith(('jpg', 'jpeg', 'png', 'tif')) else "jpg"
                    img_name = f"{base_no_ext.split('_nr_')[0]}_nr_{block_idx}_{i:04d}.{img_ext}"
                    img_path = os.path.join(folder_out, img_name)
                    page.save(img_path, fmt.upper())
                log_message(f"Extracted {len(pages)} pages as images into {folder_out}")
            except Exception as e:
                log_error(f"Image extraction failed for {pdf_out_path}: {e}")

        os.remove(pdf_path)
        log_message(f"Deleted original PDF: {pdf_path}")
        log_message("✅ Processing complete.\n")

    except Exception as e:
        log_error(f"Failed to process {pdf_path}: {e}")

def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        log_error("No input directory provided.")
        print("Usage: python3 split_x_detector.py /path/to/pdf_directory/")
        sys.exit(1)

    input_dir = sys.argv[1]

    if not os.path.isdir(input_dir):
        log_error(f"Invalid path: {input_dir}")
        sys.exit(1)

    if not os.path.isdir(TEMPLATE_DIR):
        log_error(f"Template directory not found: {TEMPLATE_DIR}")
        sys.exit(1)

    # Load templates
    templates = []
    for f in os.listdir(TEMPLATE_DIR):
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".tiff")):
            t = cv2.imread(os.path.join(TEMPLATE_DIR, f))
            if t is not None:
                templates.append(t)
    if not templates:
        log_error("No valid templates found.")
        sys.exit(1)

    log_message(f"--- Script started at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ---")
    log_message(f"Using template directory: {TEMPLATE_DIR}")
    log_message(f"Input directory: {input_dir}")

    # Process PDFs
    pdf_files = [f for f in os.listdir(input_dir) if f.lower().endswith(".pdf")]
    if not pdf_files:
        log_error("No PDF files found in input directory.")
        sys.exit(1)

    for file in pdf_files:
        pdf_path = os.path.join(input_dir, file)
        split_pdf_on_x(pdf_path, templates)

    log_message("--- Script finished successfully ---\n")

if __name__ == "__main__":
    main()
