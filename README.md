# Digital Archiving Tools

A collection of scripts, workflows, and utilities designed to support **digital archiving**, **data preservation**, and **automation tasks**.  
The tools in this repository are intended for archivists, librarians, and data managers who work with **electronic records** and need practical solutions for day-to-day operations.

---

## 📚 Features

- **File Processing** – Batch renaming, checksum generation, format conversions.
- **Metadata Handling** – Extracting and transforming metadata for archival records.
- **Automation** – Scripts to speed up repetitive tasks in digital preservation workflows.
- **Data Integrity** – Tools for verifying and validating archived files.
- **Checksum Generation** – Create and verify file checksums (MD5, SHA256, etc.).
- **Batch File Processing** – Process multiple files or directories in one go.
- **Metadata Extraction** – Read and export file metadata for archival purposes.
- **Automation Workflows** – Speed up repetitive tasks in digital preservation.

---

## 🚀 Getting Started

### Prerequisites
- **Python 3.9+** installed
- Required packages listed in `requirements.txt`

### Installation
```bash
# Clone the repository
git clone https://github.com/MustafaDemiroglu/digital-archiving-tools.git

# Go to the project folder
cd digital-archiving-tools

# Install dependencies
pip install -r requirements.txt
```

## 🛠 Usage
```bash
All scripts can be run from the command line.
Use the --help parameter to see available options.
# 1. Generate Checksums

Create checksums for all files in a folder:

python scripts/checksum_generator.py ./data --algorithm sha256

Verify existing checksums:

python scripts/checksum_verifier.py ./data/checksums.sha256

# 2. Batch Rename Files

Rename files according to a pattern:

python scripts/batch_rename.py ./data --pattern "archive_{index}.tif"

# 3. Extract Metadata

Extract and save file metadata to CSV:

python scripts/metadata_extractor.py ./data --output metadata.csv
```

## 📄 Documentation

    Detailed guides are available in the docs/ folder.

    Example workflows can be found in the examples/ folder.

## 🤝 Contributing

We welcome contributions!

    Fork the repository

    Create a new branch:

git checkout -b feature-name

Commit your changes:

    git commit -m "Add new feature"

    Push to your branch and create a Pull Request

## 📜 License

This project is licensed under the MIT License – see the LICENSE file for details.
📧 Contact

If you have questions or suggestions, please open an Issue in this repository or email me at: mustafa.demiroglu@gmx.de

## 📂 Repository Structure
```plain text
digital-archiving-tools/
│
├── scripts/          # Command-line tools and helper scripts
├── workflows/        # Automation workflows and batch processing templates
├── docs/             # Documentation and usage guides
├── examples/         # Example datasets and configuration files
├── LICENSE
└── README.md
```
