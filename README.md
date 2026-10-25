# zpdf

Fast, dependency-free PDF **text extraction** in Zig.

This is a hardened fork of [Lulzx/zpdf](https://github.com/Lulzx/zpdf) (CC0).
It keeps the zero-copy design and the focus on text, and fixes the defects found
by running it against 50 real-world PDFs (773 pages, Chinese + English, Office
exports, Keynote/pdfcpu rewrites, scanned files).

- **Text only.** No rendering, no OCR, no models, no image decoding.
- **~7× faster than poppler** on the reference corpus (in-process: 0.14 s vs
  1.00 s for 50 PDFs / 773 pages).
- **99.3 % of poppler's characters**, with cleaner output (no zero-width
  characters, no U+FFFD, no Kangxi-radical leaks).
- **No dependencies.** Pure Zig, compiles to a small static library.

## Performance and accuracy

Corpus: 50 unique PDFs from a real download directory, 773 pages, 38 with a text
layer (the other 12 are scans). Same machine, warm cache, warm-up + 3 runs,
median. All engines in-process except where noted.

| engine | total | median ms/page | mean coverage vs poppler | empty* |
|---|---:|---:|---:|---:|
| **zpdf** | **0.14 s** | **0.10** | **0.993** | **0** |
| poppler (docconv) | 1.00 s | 0.57 | 1.000 | 0 |
| MuPDF / PyMuPDF | 0.84 s | 0.67 | 0.999 | 0 |
| PDFium / pypdfium2 | 1.07 s | 0.71 | 0.995 | 0 |
| pdf_oxide | 1.42 s | 1.31 | 0.914 | 0 |
| upstream zpdf (CLI) | 0.23 s | 0.81 | 0.913 | 3 |

\* text present in poppler but the engine returned nothing.

Output hygiene on the same corpus:

| engine | Kangxi radicals | zero-width chars | U+FFFD/FFFE |
|---|---:|---:|---:|
| **zpdf** | **0** | **0** | **0** |
| poppler | 0 | 139 | 77 |
| PDFium | 0 | 0 | 49 |
| MuPDF | 0 | 139 | 77 |

Selected documents:

| document | zpdf | poppler | notes |
|---|---:|---:|---|
| NVIDIA SN6000 manual (80 p) | 88,353 ch / 16 ms | 87,903 ch / 45 ms | same content |
| 通达信指标教程 (67 p) | 55,869 ch / 6 ms | 50,671 ch / 59 ms | broken xref recovered |
| FBB form PDF (1 p) | 34,999 ch / 3 ms | 23,878 ch / 10 ms | text inside Form XObjects |
| 分布式部署架构图 (2 p) | 77 lines | 154 fragmented lines | per-glyph PDF |
| 中原消金API梳理 (1 p) | 13 lines | 61 fragmented lines | per-glyph PDF |

## What was fixed vs upstream

1. **XRef recovery** — tolerate EOL before `xref` / xref-stream objects, and do
   not reject a table because the free-list head uses generation 65536.
   Two real PDFs went from 0 pages to full text.
2. **Form XObject fonts** — follow nested forms and load fonts from each form's
   own `/Resources` with a per-form cache. A PDF whose page content was only
   `/Fm1 Do /Fm2 Do` extracted nothing before.
3. **Unicode clean-up** — map Kangxi radicals / CJK compatibility ideographs to
   unified codepoints (NFKC + Unicode `EquivalentUnifiedIdeograph`), fold
   fullwidth alphanumerics and ligatures, drop zero-width characters and
   noncharacters. CJK output went from `云原⽣` to `云原生`.
4. **Line reconstruction** — track the CTM (`q`/`Q`/`cm`) and break lines on
   device-space baseline changes; inherit the CTM into forms. Diagram PDFs went
   from one line per page to proper lines without losing characters.
5. **Font glyph names** — resolve `/Differences` names used by foundry fonts
   (`f_l`, `T_h`, `zero.oldstyle`, `a.sc`, …) by splitting components and
   stripping suffixes. This recovered missing digits and ligatures on the
   opendataloader corpus (see below).

See [docs/FORK.md](docs/FORK.md) for details and the comparison methodology.

## External corpus (opendataloader-bench)

The 200-document corpus used by `pdf-inspector` / opendataloader-bench (200
pages, English, Markdown ground truth). Accuracy is measured against the plain
text of the ground truth: 4-gram F1 (content, order-insensitive) and LCS
coverage (order-aware recall), micro-averaged per document. All engines
in-process, warm cache, warm-up + 3 runs.

| engine | F1 mean | F1 median | LCS mean | LCS median | total | median ms/doc |
|---|---:|---:|---:|---:|---:|---:|
| **zpdf** | 0.927 | **0.961** | **0.922** | **0.972** | **0.06 s** | **0.20** |
| poppler (CLI) | **0.936** | 0.962 | 0.920 | 0.970 | 2.06 s | 9.87 |
| pdf-inspector | 0.922 | 0.953 | 0.914 | 0.960 | 0.16 s | 0.50 |
| pdf_oxide | 0.920 | 0.938 | 0.903 | 0.950 | 0.46 s | 2.00 |

zpdf is **2.5× faster than pdf-inspector, 10× faster than pdf_oxide** and has
the best median/mean LCS. The 0.9-point F1 gap to poppler comes from five
documents where zpdf also extracts an additional text layer that the ground
truth (and poppler) omit; on the 194 text-layer documents zpdf scores 0.941 F1
/ 0.935 LCS vs poppler 0.948 / 0.935.

> pdf_oxide's own 356/3,830-PDF corpus is not published, so it was evaluated on
> this same 200-document set.

## Build

Requires Zig **0.17.0**.

```bash
zig build -Doptimize=ReleaseFast          # CLI + Zig library
./zig-out/bin/zpdf extract document.pdf
./zig-out/bin/zpdf info document.pdf
```

Static C API (for `zpdf-go` and other bindings):

```bash
zig build capi -Doptimize=ReleaseFast
# -> zig-out/lib/libzpdf_c.a
# -> zig-out/include/zpdf.h
```

Cross-compile for the Go module:

```bash
zig build capi -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu   --prefix /tmp/zpdf-linux-amd64
zig build capi -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu  --prefix /tmp/zpdf-linux-arm64
```

## CLI

```bash
zpdf extract document.pdf              # text, structure/reading order when tagged
zpdf extract -p 1-10 document.pdf      # page range
zpdf extract -o out.txt document.pdf
zpdf extract -f json document.pdf
zpdf info document.pdf                 # pages, metadata, outline, sizes
zpdf search "invoice number" document.pdf
zpdf bench document.pdf                # throughput
```

## C API

```c
#include "zpdf.h"

zpdf_document *doc = zpdf_open_memory_copy(data, len); /* safe copy */
if (!doc) { /* zpdf_last_error() */ }

size_t n = 0;
uint8_t *text = zpdf_extract_all_fast(doc, &n);  /* stream order */
fwrite(text, 1, n, stdout);
zpdf_free_buffer(text, n);

zpdf_close(doc);
```

- `zpdf_extract_all_fast` — content-stream order (closest to `pdftotext -raw`,
  with line repair).
- `zpdf_extract_all` — reading order (structure tree, geometric fallback).
- `zpdf_open_memory` borrows the buffer; `zpdf_open_memory_copy` owns a copy.
- `zpdf_last_error()` is thread-local; documents are independent.

A Go binding lives at [Servicewall/zpdf-go](https://github.com/Servicewall/zpdf-go)
(static libraries and cgo hidden behind a normal Go API).

## Page images for OCR (opt-in)

Callers that need to OCR scanned pages can pull the page images; the text path
is unchanged and pays nothing unless this is called.

```c
ZpdfPageImage *imgs; size_t n;
if (zpdf_extract_page_images(doc, 0, &imgs, &n) == 0) {
    /* imgs[i].format: RGB24 / GRAY8 / JPEG / CCITT / JPX */
    zpdf_free_page_images(imgs, n);
}
```

- JPEG (`DCTDecode`) is returned as-is — no re-encode, no render.
- Flate/LZW/RunLength samples are converted to RGB24 or GRAY8
  (gray/rgb/cmyk/indexed, bpc 1 and 8; PNG predictors supported).
- CCITT is returned raw with `K` / `BlackIs1` for a fax decoder.
- JPX is returned raw; zpdf does not ship a JPEG2000 decoder.
- Limits: max 8 images/page, min 64 px, max 40 MP; `/ImageMask` and `/SMask`
  are skipped.

Go: `doc.PageImages(page)` in `zpdf-go` v0.2.0+.

See [docs/image-extraction.md](docs/image-extraction.md) for the full design.

## Accuracy tests (CJK)

End-to-end tests cover the encodings Chinese PDFs actually use:

- Type0 `/Identity-H` + ToUnicode CMap, with a sentence mixing Chinese,
  fullwidth punctuation and digits (`中文编码测试：2026，ABC！`)
- Type0 `/UniGB-UCS2-H` without ToUnicode (code == Unicode)
- supplementary plane characters (U+20000) through ToUnicode surrogate pairs
- Kangxi radicals / CJK compatibility ideographs mapped to unified codepoints,
  fullwidth alphanumerics folded, zero-width characters dropped
- xref recovery, Form XObject fonts and `cm`-positioned line breaks

For real documents, create `testdata/cjk_regression.tsv` with one
`pdf<TAB>reference.txt` per line (reference text from human transcription,
`pdftotext -raw`, or another trusted extractor) and run `zig build test`.
Both sides are normalised (whitespace, zero-width, Kangxi/fullwidth) and
compared as character 4-gram recall/F1; the gate fails if any document has
recall < 0.95 or the mean is < 0.98. The test skips when the file is absent.

On a local 37-document Chinese corpus (reference: `pdftotext -raw`):

```
mean recall = 0.9992   mean F1 = 0.9947   failures = 0
```

## Tests and gates

```bash
zig build test    # full suite
zig build gate    # regression + benchmark gate (200 pages, floor 100 pages/s)
```

The benchmark gate measures a 200-page fixture and fails if throughput drops
below 100 pages/s or the first/last page text is missing. On a laptop it runs at
>50k pages/s.

## Limitations

- **Text only** — no page rendering, no image extraction, no OCR.
- **Broken fonts** — PDFs whose ToUnicode maps UTF-8 bytes as Windows-1252
  (rare) are still returned as mojibake; pdf_oxide repairs those, zpdf does not.
- **CID fonts without ToUnicode** — decoding falls back to Identity/UTF-16 and
  CFF glyph names; subset TrueType fonts that only carry glyph IDs may produce
  missing text until a `cmap` fallback is added.
- **Encrypted PDFs** — detected (`zpdf_is_encrypted`) but no password entry.
- **Zig 0.15.2** — 0.16/0.17 need an `std.Io` migration.

## License

CC0-1.0, same as upstream. Upstream: [Lulzx/zpdf](https://github.com/Lulzx/zpdf).
