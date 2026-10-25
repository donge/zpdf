# zpdf

Fast, dependency-free PDF **text extraction** in Zig.

This is a hardened fork of [Lulzx/zpdf](https://github.com/Lulzx/zpdf) (CC0).
It keeps the zero-copy design and the focus on text, and fixes the defects found
by running it against 50 real-world PDFs (773 pages, Chinese + English, Office
exports, Keynote/pdfcpu rewrites, scanned files).

- **Text only.** No rendering, no OCR, no models, no image decoding.
- **~5× faster than poppler** on the reference corpus (in-process: 0.18 s vs
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
| **zpdf** | **0.18 s** | **0.16** | **0.993** | **0** |
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

See [docs/FORK.md](docs/FORK.md) for details and the comparison methodology.

## Build

Requires Zig **0.15.2**.

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

## Tests and gates

```bash
zig build test    # 591 tests
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
