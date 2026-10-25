#!/usr/bin/env python3
"""Extract all text from a PDF to a text file."""
import sys
sys.path.insert(0, "python")

import zpdf

if len(sys.argv) < 2:
    print("Usage: extract_to_file.py <input.pdf> [output.txt]")
    sys.exit(1)

input_path = sys.argv[1]
output_path = sys.argv[2] if len(sys.argv) > 2 else input_path.replace(".pdf", ".txt")

with zpdf.Document(input_path) as doc:
    print(f"Extracting {doc.page_count} pages...")
    text = doc.extract_all()

with open(output_path, "w") as f:
    f.write(text)

print(f"Saved to {output_path}")
