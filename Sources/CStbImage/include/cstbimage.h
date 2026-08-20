/*
 * cstbimage.h
 *
 * Minimal, dependency-free C image decoding primitives for ForensicLens.
 *
 * DESIGN NOTE
 * -----------
 * This is NOT a vendored copy of stb_image.h. Pulling in the full
 * single-header stb_image library would drag several thousand lines of C
 * into the tree for formats ForensicLens doesn't even need. So instead this
 * file hand-implements just enough of a decoder to:
 *
 *   1. Decode uncompressed 24/32-bit Windows BMP files.
 *   2. Decode binary PPM (P6) and PGM (P5) "Netpbm" images, which are used
 *      throughout the test suite as a trivially-constructible synthetic
 *      image format (no compression, no metadata quirks).
 *   3. Expose a baseline-JPEG entry point that is documented as a stub. A
 *      correct baseline JPEG decoder (Huffman tables, IDCT, chroma
 *      upsampling, etc.) is out of scope for this project; see the doc
 *      comment on cstbi_decode_jpeg_baseline below for details on what a
 *      full implementation would require.
 *
 * All decode functions follow the same contract: on success they return 0
 * and allocate `*out_pixels` (caller must free with cstbi_free); on failure
 * they return a negative CSTBI_ERR_* code and leave `*out_pixels` untouched.
 *
 * This header is the ONLY public surface of the CStbImage target. Swift code
 * outside of the `ImageDecoding` module must never import this module
 * directly -- see Sources/ImageDecoding/ImageDecoder.swift.
 */

#ifndef CSTBIMAGE_H
#define CSTBIMAGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes returned by the decode functions below. */
#define CSTBI_OK                0
#define CSTBI_ERR_TRUNCATED    -1
#define CSTBI_ERR_BAD_MAGIC    -2
#define CSTBI_ERR_UNSUPPORTED  -3
#define CSTBI_ERR_ALLOC        -4
#define CSTBI_ERR_DIMENSIONS   -5
#define CSTBI_ERR_NOT_IMPLEMENTED -6

/*
 * Decodes an uncompressed 24-bit or 32-bit Windows BMP image.
 *
 * On success, `*out_pixels` is allocated with `width * height * channels`
 * bytes, laid out top-to-bottom, left-to-right, with `channels` interleaved
 * bytes per pixel in RGB (or RGBA) order. `channels` is set to 3 or 4 to
 * match the source bit depth.
 *
 * Only the BITMAPINFOHEADER (40-byte) variant with BI_RGB (uncompressed)
 * compression is supported, which covers the vast majority of BMP files
 * produced by test fixtures and simple tools. Paletted, RLE-compressed, and
 * BITMAPV4/V5 headers are rejected with CSTBI_ERR_UNSUPPORTED.
 */
int cstbi_decode_bmp(const unsigned char *data, size_t len,
                      int *width, int *height, int *channels,
                      unsigned char **out_pixels);

/*
 * Decodes a binary PPM (P6, RGB) or PGM (P5, grayscale) Netpbm image.
 *
 * Only the binary (not ASCII) variants with a maxval of 255 are supported,
 * which is sufficient for the synthetic images this project generates for
 * itself. `channels` is set to 3 for PPM or 1 for PGM.
 */
int cstbi_decode_ppm(const unsigned char *data, size_t len,
                      int *width, int *height, int *channels,
                      unsigned char **out_pixels);

/*
 * Baseline JPEG decode entry point -- NOT IMPLEMENTED.
 *
 * A conformant baseline JPEG decoder needs, at minimum: marker segment
 * parsing (SOI/APPn/DQT/SOF0/DHT/SOS/EOI), Huffman table construction and
 * entropy decoding of the scan, dequantization, inverse DCT per 8x8 block,
 * and chroma (4:2:0 / 4:2:2) upsampling plus YCbCr -> RGB conversion. That
 * is substantial and orthogonal to the forensic analysis logic this project
 * exists to demonstrate.
 *
 * This function always returns CSTBI_ERR_NOT_IMPLEMENTED. It exists so the
 * Swift decoding layer has a single, clearly-documented seam where a real
 * decoder (or a vendored stb_image.h) could be dropped in later without
 * changing any call site above ImageDecoding.
 */
int cstbi_decode_jpeg_baseline(const unsigned char *data, size_t len,
                                int *width, int *height, int *channels,
                                unsigned char **out_pixels);

/* Frees a buffer allocated by any cstbi_decode_* function. */
void cstbi_free(unsigned char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* CSTBIMAGE_H */
