# Fork notes

Upstream: [Lulzx/zpdf](https://github.com/Lulzx/zpdf) @ `7ea3458` (2026-08-13), CC0-1.0.

This fork keeps upstream's design (zero-copy, stream-order extraction, no
dependencies, Zig 0.15.2) and fixes defects found while comparing it with
poppler on 50 real-world PDFs (773 pages, 38 with a text layer, Chinese and
English, including Office exports, Keynote/pdfcpu rewrites and scanned files).

## Fixes

### 1. XRef parsing (`src/xref.zig`)

* Skip EOL/whitespace between the `startxref` offset and the `xref` keyword or
  xref-stream object. Some writers emit `\r\nxref`, which upstream treated as
  an xref stream and failed to parse.
* Do not reject the entire table when a generation number does not fit in a
  `u16`. The free-list head (object 0) is commonly written with generation
  65536; upstream returned `InvalidXrefTable` for the whole document.

Effect: two real PDFs went from `Pages: 0` to full text
(`最新版通达信指标公式教程.pdf`, 67 pages; `dongdong_cn (1).pdf`, 3 pages).

### 2. Form XObjects (`src/root.zig`)

* `extractAllTextFast` / stream-order extraction now use the full extraction
  path with a non-null context, so `/XObject ... Do` is followed.
* Each Form XObject gets a private font cache built from its own
  `/Resources /Font`. Before, only page-level fonts were visible (fonts inside
  forms were never loaded), and a shared page-level cache would have mixed
  identically named fonts in different forms.

Effect: a PDF whose entire page content is `/Fm1 Do /Fm2 Do` produced 0 bytes
before and now extracts 43 KB of text. Nested forms are handled recursively
(depth limit 10).

### 3. Unicode clean-up (`src/encoding.zig`, `src/unicode_norm.zig`)

Generated table (from Unicode NFKC + `EquivalentUnifiedIdeograph.txt`) applied
to every decoded codepoint:

* Kangxi radicals and CJK Radicals Supplement → unified ideographs
  (`云原⽣` → `云原生`, `接⼊` → `接入`). NFKC alone does not cover the
  Radicals Supplement; the Unicode property does.
* CJK compatibility ideographs → unified ideographs.
* Fullwidth alphanumerics and Latin ligatures are folded; fullwidth
  punctuation (，：；) is preserved.
* Zero-width/format characters (U+200B–U+200F, U+FEFF, soft hyphen, …) and
  noncharacters (U+FFFD–U+FFFF) are dropped.

Effect: CJK keyword matching works; poppler leaves 139 U+200B in the same
corpus and U+FFFD for checkbox glyphs.

## Benchmark

Same machine (Apple Silicon, macOS 26), same 50 unique PDFs from `~/Downloads`
(773 pages, 38 with a text layer; 12 are scanned and have no text layer).
Each file was run once as warm-up, then 3 times; median reported. zpdf timings
include process start (CLI); poppler was measured in-process through docconv
(`poppler-cpp`, `raw_order_layout`).

| | upstream zpdf | this fork | poppler (docconv) |
|---|---:|---:|---:|
| total wall time | 0.21 s | 0.29 s | 1.00 s |
| median ms/page | 0.52 | 0.63 | 0.57 (in-process) |
| text docs returning nothing | **3** | **0** | 12 scanned (expected) |
| content coverage, mean (NFKC, vs poppler) | 0.913 | **0.993** | 1.000 |
| Kangxi radicals left | many | **0** | 0 |
| U+200B left | — | **0** | 139 |

Largest files, whole-document wall time:

| document | pages | zpdf fork | poppler |
|---|---:|---:|---:|
| NVIDIA SN6000 manual (35 MB) | 80 | 20 ms | 45 ms |
| guard-small-models v0.2.0 | 74 | 23 ms | 184 ms |
| 最新版通达信指标公式教程 | 67 | 9 ms | 59 ms |
| 乐信技术应答 | 29 | 10 ms | 27 ms |

Per-glyph diagram PDFs (Keynote → pdfcpu) where poppler emits 1–3 character
lines: zpdf returns complete words (`云原生-异地分布(代理部署)`,
`数据报表接口`, `管理面板`) with 100% of poppler's characters.

## Known limitations / next steps

* **Mojibake PDFs.** `最终验证.pdf` has a broken ToUnicode that maps UTF-8
  bytes as Windows-1252. Poppler and zpdf both return `è·¨å¢ƒ...`; pdf_oxide is
  the only engine that repairs it. A conservative per-line repair could be
  added behind a flag.
* **Visual line reconstruction.** Text is emitted in content-stream order with
  line breaks on matrix changes. Prose keeps normal lines; diagram PDFs are
  emitted as one long line per page (words intact). A geometry pass over spans
  (already collected by `extractTextWithBounds`) could add line breaks.
* **CID fonts without ToUnicode.** Decoding falls back to Identity/UTF-16 and
  CFF glyph names. A TrueType `cmap` fallback would cover subset fonts that
  only carry glyph IDs.
* **Zig version.** Upstream targets Zig 0.15.2; this fork is built and tested
  with `zig@0.15` (0.16/0.17 need an `std.Io` migration).

## Build

```bash
brew install zig@0.15            # or download Zig 0.15.2
zig build -Doptimize=ReleaseFast
./zig-out/bin/zpdf extract file.pdf
```

## Tests

```bash
zig build test    # 143 + 2 tests
```
