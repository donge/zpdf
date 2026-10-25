# Minimal image extraction for OCR

> Status: design only. Goal: let a caller pull the page images out of a PDF and
> hand them to an OCR engine, without adding a renderer and without changing the
> text path for callers that do not ask for images.

## 1. Switch semantics

There is **no global flag**. Image extraction is an explicit call:

- `zpdf_extract_page_images()` (C) / `PageImages()` (Go) does the work.
- Callers that never call it pay nothing: the text path is unchanged, no
  per-page image scanning, no extra allocations.
- docconv's switch is the existing `ocr=true` plus a **per-page text threshold**:
  only pages whose native text is shorter than ~20 characters are sent to OCR.
  A text PDF with `ocr=true` therefore performs zero image work.

This keeps the feature opt-in and avoids a doc-wide mode that would change
performance for existing users.

## 2. API

### Zig

```zig
pub const ImageFormat = enum(u8) { rgb24, gray8, jpeg, ccitt, jpx };

pub const PageImage = struct {
    rect: [4]f64,       // placement in page coordinates
    width: u32,
    height: u32,
    format: ImageFormat,
    bpc: u8,
    colorspace: enum(u8) { gray, rgb, cmyk, indexed },
    data: []u8,         // owned by the caller's allocator
};

pub fn extractPageImages(
    self: *Document,
    page: usize,
    allocator: std.mem.Allocator,
) ![]PageImage;
```

### C ABI (v2; v1 text API stays untouched)

```c
#define ZPDF_ABI_VERSION 2

typedef struct {
    int32_t  page;
    int32_t  index;
    double   x0, y0, x1, y1;
    uint32_t width, height;
    int32_t  format;      // 0=RGB24 1=GRAY8 2=JPEG 3=CCITT 4=JPX
    int32_t  bpc;
    int32_t  colorspace;  // 0=gray 1=rgb 2=cmyk 3=indexed
    uint8_t *data;
    size_t   len;
} ZpdfImage;

int  zpdf_extract_page_images(void *doc, int page,
                              ZpdfImage **out, size_t *count);
void zpdf_free_images(ZpdfImage *ptr, size_t count);
```

`zpdf_extract_page_images` returns page images in content-stream order; the
caller frees the array and each `data` with `zpdf_free_images`.

### Go (`Servicewall/zpdf-go`)

```go
type ImageFormat int

const (
    ImageRGB24 ImageFormat = iota
    ImageGray8
    ImageJPEG
    ImageCCITT
    ImageJPEG2000
)

type Image struct {
    Page        int
    Rect        [4]float64
    Width       int
    Height      int
    Format      ImageFormat
    BPC         int
    Data        []byte // copied; safe after the call
}

func (d *Document) PageImages(page int) ([]Image, error)
```

`Data` is copied with `C.GoBytes` and the C buffer freed immediately, so the Go
slice does not alias the document.

## 3. Implementation (minimal)

Reuse the content-stream walker already used for text:

1. Walk the page content with a `q`/`Q`/`cm` stack (same logic as the text
   extractor), following `Do` into Form XObjects with inherited CTM and
   resolved `/Resources` (including indirect references).
2. For each XObject with `/Subtype /Image`, record its placement rect and
   intrinsic size. Inline images (`BI … EI`) are **out of scope** for v1.
3. Decode only what OCR needs:

| PDF filter | Output | Notes |
|---|---|---|
| `DCTDecode` | `jpeg` (raw bytes) | zero decode; pureocr decodes |
| `FlateDecode` + DeviceGray/RGB/Indexed | `gray8` / `rgb24` | expand bpc 1/2/4/8, apply `/Decode`, palette lookup |
| `FlateDecode` + CMYK | `rgb24` | simple CMYK→RGB |
| `LZWDecode` / `RunLengthDecode` | same as Flate | decompress.zig already handles them |
| `CCITTFaxDecode` | `ccitt` (raw + params) | Go side decodes with `x/image/ccitt` |
| `JPXDecode` | `jpx` (raw bytes) | **skipped by docconv** (no Go decoder) |

Filters/predictors are already implemented in `decompress.zig`.

4. Skip `/ImageMask` and `/SMask`; OCR needs the base image, not masks.
5. Limits (hard-coded constants):
   - max 8 images per page (largest by area)
   - max 40 MP per image, max 32 MB of pixel data
   - min 64 px on either side (skip icons/logos)
6. Rotation: return the stored pixels; pureocr already handles 90/180/270 and
   small tilt, so no pre-rotation.

## 4. docconv OCR pipeline

```
Convert(r, "pdf", ocr=true)
  zpdf.Open(data)
    page_count
    for page in 0..N:
        native = PageText(page)
        if rune_len(trim(native)) >= 20:
            append native              # no image work
            continue
        imgs = PageImages(page)        # opt-in call
        pick images with area >= 15% of page (or the largest)
        for img:
            switch img.Format:
              JPEG  -> pureocr.OCRBytes(img.Data)
              RGB24 -> pureocr.OCRRGB(img.Data, w, h, w*3)
              GRAY8 -> pureocr.OCRGray(img.Data, w, h, w)
              CCITT -> ccitt.NewReader -> image.Gray -> OCRGray
              JPX   -> skip (page stays without OCR text)
        page_text = native + "\n" + ocr_text
```

- `golang.org/x/image/ccitt` is already available through the existing
  `golang.org/x/image` dependency; no new module.
- docx embedded-image OCR is unchanged.
- If a scanned page has no usable image (vector-only, JPX, unsupported
  colorspace), the page keeps its native text (usually empty). No renderer.
- Optional later: an `ocr=all` mode that also OCRs significant images on pages
  that already have text, with a dedupe pass.

## 5. Tests and gates

zpdf (`src/image_test.zig`):

- JPEG image XObject → `format=jpeg`, exact bytes
- Flate RGB24 and Gray8 → dimensions and pixel checksum
- Indexed palette → RGB24
- Image inside a nested Form with indirect `/Resources` (regression for v0.2.1)
- ImageMask is skipped
- Limits: oversized image is skipped

zpdf-go:

- `PageImages(0)` returns one JPEG image and the bytes decode with
  `image/jpeg`.

docconv:

- Scan fixture (`实施-中原消金-业务安全.pdf`, 2 pages): OCR text contains
  `API安全平台` / `运行概览`.
- Text PDF: `ocr=true` must not call `PageImages` (add a counter or benchmark
  assertion).
- CJK accuracy gate unchanged; add a scanned-page OCR assertion.

Benchmark: scanned page should be ≤ the old render+OCR path (previously
112–240 ms/page); JPEG passthrough removes the 225 dpi render entirely.

## 6. Effort and risks

| Work | Days |
|---|---:|
| zpdf image walker + filters + C ABI | 2–3 |
| zpdf-go binding | 0.5 |
| docconv per-page OCR + CCITT/JPEG paths | 1 |
| tests + benchmark | 1 |
| **total** | **4–5** |

Risks:

- CCITT variants (G3/G4, `BlackIs1`, byte/row alignment) need real scans to
  validate; Go's `ccitt.Options` covers the common cases.
- Tiled scans produce many images; the pipeline takes the largest and/or OCRs
  all images above the area threshold, then joins.
- CMYK/Indexed conversions can shift colors; OCR is grayscale-tolerant.
- JPX scanning remains unsupported; documented.
- Inline images are out of scope for v1; add if a real corpus needs them.
