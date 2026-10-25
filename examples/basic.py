#!/usr/bin/env python3
"""Basic text extraction example."""
import sys
sys.path.insert(0, "python")

import zpdf

with zpdf.Document("test.pdf") as doc:
    print(f"Pages: {doc.page_count}")

    # Extract first page
    text = doc.extract_page(0)
    print(f"\n--- Page 1 ---\n{text[:500]}...")
