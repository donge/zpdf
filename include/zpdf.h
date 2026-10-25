/*
 * zpdf C API — text extraction only.
 *
 * Strings/buffers returned by zpdf_extract_* are owned by the caller and must
 * be released with zpdf_free_buffer(ptr, len).
 *
 * ABI version: bump on incompatible changes (see zpdf_abi_version()).
 */
#ifndef ZPDF_H
#define ZPDF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zpdf_document zpdf_document;

/* 2 */
uint32_t zpdf_abi_version(void);

/* Last error for the calling thread (0 = none). */
int zpdf_last_error(void);

/* Open from a file path (the file is memory-mapped by zpdf). */
zpdf_document *zpdf_open(const char *path);

/* Open from a copy: the caller may free `data` immediately. */
zpdf_document *zpdf_open_memory_copy(const uint8_t *data, size_t len);

/* Open by borrowing `data`: it must stay alive and unchanged until close. */
zpdf_document *zpdf_open_memory(const uint8_t *data, size_t len);

void zpdf_close(zpdf_document *doc);

int zpdf_page_count(zpdf_document *doc);
bool zpdf_is_encrypted(zpdf_document *doc);

/* Text, stream order (equivalent to `pdftotext -raw` plus line repair). */
uint8_t *zpdf_extract_all_fast(zpdf_document *doc, size_t *out_len);

/* Text, reading order (structure tree when tagged, geometric otherwise). */
uint8_t *zpdf_extract_all(zpdf_document *doc, size_t *out_len);

/* Text of one page, stream order. */
uint8_t *zpdf_extract_page(zpdf_document *doc, int page, size_t *out_len);

void zpdf_free_buffer(uint8_t *ptr, size_t len);

/* ---- Page images for OCR (opt-in) ---- */

typedef struct {
    int32_t page;
    int32_t index;
    double x0, y0, x1, y1;
    uint32_t width, height;
    int32_t format;      /* 0=RGB24 1=GRAY8 2=JPEG 3=CCITT 4=JPX */
    int32_t bpc;
    int32_t colorspace;  /* 0=gray 1=rgb 2=cmyk 3=indexed */
    int32_t ccitt_k;
    bool black_is_1;
    uint8_t *data;
    size_t len;
} ZpdfPageImage;

/* Returns 0 on success; *out must be freed with zpdf_free_page_images. */
int zpdf_extract_page_images(zpdf_document *doc, int page,
                             ZpdfPageImage **out, size_t *count);
void zpdf_free_page_images(ZpdfPageImage *ptr, size_t count);

/* MediaBox size and page rotation (0/90/180/270). Returns 0 on success. */
int zpdf_get_page_info(zpdf_document *doc, int page,
                       double *width, double *height, int *rotation);

#ifdef __cplusplus
}
#endif

#endif /* ZPDF_H */
