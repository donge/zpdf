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

### 3. Line reconstruction (`src/root.zig`, `src/layout.zig`)

* Stream-order extraction now tracks the CTM (`q`/`Q`/`cm`) and the text
  matrix, and breaks lines when the **device-space** origin moves to another
  baseline. Before, only `Tm`/`Td` in text space were compared, so PDFs that
  position text with `cm` (Keynote/pdfcpu exports) came out as one line per
  page. The CTM is inherited by Form XObjects.
* Structure-tree output joins marked-content blocks with newlines instead of
  spaces (and drops empty blocks), so tagged PDFs keep their paragraph
  structure.

Effect on the two worst diagram PDFs:

| document | poppler | fork before | fork now |
|---|---:|---:|---:|
| 分布式部署架构图 | 154 fragmented lines | 3 lines | **77 lines** |
| 中原消金API梳理要点 | 61 fragmented lines | 8 lines | **13 lines** |

(PDFium/PDFKit produce 66 and 13 lines respectively on these files.)

### 4. Unicode clean-up (`src/encoding.zig`, `src/unicode_norm.zig`)

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
| total wall time | 0.21 s | **0.25 s** | 1.00 s |
| median ms/page | 0.52 | **0.57** | 0.57 (in-process) |
| text docs returning nothing | **3** | **0** | 12 scanned (expected) |
| content coverage, mean (NFKC, vs poppler) | 0.913 | **0.993** | 1.000 |
| Kangxi radicals left | many | **0** | 0 |
| U+200B left | — | **0** | 139 |

Largest files, whole-document wall time:

| document | pages | zpdf fork | poppler |
|---|---:|---:|---:|
| NVIDIA SN6000 manual (35 MB) | 80 | 20 ms | 45 ms |
| guard-small-models v0.2.0 | 74 | 21 ms | 184 ms |
| 最新版通达信指标公式教程 | 67 | 8 ms | 59 ms |
| 乐信技术应答 | 29 | 10 ms | 27 ms |

Per-glyph diagram PDFs (Keynote → pdfcpu) where poppler emits 1–3 character
lines: zpdf returns complete words (`云原生-异地分布(代理部署)`,
`数据报表接口`, `管理面板`) with 100% of poppler's characters.

## Tests and gates

`zig build test` runs the full suite (591 tests). The gate files are:

* `src/regression_test.zig` — one synthetic PDF per fixed defect:
  CRLF-before-`xref` + generation 65536, text only reachable through a Form
  XObject font, identical `/F1` names in two forms with different fonts,
  ToUnicode → Kangxi radical mapping, `cm`-positioned lines, and the Unicode
  table invariants.
* `src/bench_gate.zig` — a 200-page fixture that must extract at more than
  **100 pages/s** (real hardware does >10k) and must contain the first and last
  page text. It fails the build on accidental O(n²) work or per-page reloads.

`zig build gate` runs the two gate files explicitly (187 tests including the
root module); CI runs `zig build test` and `zig build gate` on Zig 0.15.2, plus
`zig fmt --check`. The bench gate prints its measured throughput, e.g.
`200 pages in 3 ms (56925 pages/s, floor 100)`.

## Known limitations / next steps

* **Mojibake PDFs.** `最终验证.pdf` has a broken ToUnicode that maps UTF-8
  bytes as Windows-1252. Poppler and zpdf both return `è·¨å¢ƒ...`; pdf_oxide is
  the only engine that repairs it. A conservative per-line repair could be
  added behind a flag.
* **CID fonts without ToUnicode.** Decoding falls back to Identity/UTF-16 and
  CFF glyph names. A TrueType `cmap` fallback would cover subset fonts that
  only carry glyph IDs.
* **Zig version.** Upstream targets Zig 0.15.2; this fork is built and tested
  with `zig@0.15` (CI pinned to 0.15.2; 0.16/0.17 need an `std.Io` migration).

## Build

```bash
brew install zig@0.15            # or download Zig 0.15.2
zig build -Doptimize=ReleaseFast
./zig-out/bin/zpdf extract file.pdf
```

## Tests

```bash
zig build test    # 591 tests (unit + regression + bench gate)
zig build gate    # regression + benchmark gate only
```
