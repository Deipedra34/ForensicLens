# Algorithm notes

This is a deeper look at how each analyzer works, for anyone extending or auditing them. The short version of each lives as doc comments right above the relevant type; this file has room to go a bit further into the "why" without cluttering the source.

## Error Level Analysis (`Sources/ForensicLens/Analyzers/ELAAnalyzer.swift`)

ForensicLens doesn't carry a real JPEG encoder, so ELA doesn't actually re-save a JPEG file. Instead `JPEGRecompressionSimulator` performs the one lossy step that matters -- level shift, 8x8 block DCT, quantize at the configured quality, dequantize, inverse DCT -- directly against the decoded `PixelBuffer`. That's the exact operation a real encoder's lossy stage performs; skipping entropy coding and the container format doesn't change the error signature ELA is looking for, and it means the analyzer works identically on every format the package can decode instead of JPEG specifically.

The DCT itself (`DCT8x8`) is a direct, separable implementation with a precomputed cosine table -- there's no benefit to an FFT-based transform at a fixed 8x8 block size, and a direct implementation is much easier to verify by hand.

Two config knobs shape the result:

- `qualityLevel` controls how aggressively the quantization tables round coefficients toward zero. This is the classic ELA sensitivity/noise trade-off: coarser quantization (lower quality) makes genuine edits stand out more but also makes untouched high-frequency content (edges, text, fine texture) noisier.
- `errorThreshold` and `flaggedRegionFraction` control how the per-pixel error map gets turned into a small number of reported "regions" -- the map is bucketed into 16x16 reporting cells, and a cell counts as "hot" once its mean error crosses the threshold.

## EXIF / metadata analysis (`Sources/ForensicLens/Analyzers/MetadataAnalyzer.swift`)

EXIF lives in a JPEG's `APP1` marker segment, which sits in the file header before any compressed pixel data -- so this analyzer never needs a working JPEG pixel decoder. `ExifReader` walks the JPEG's marker segments looking for `APP1` with an `Exif\0\0` preamble, then parses just enough of the embedded TIFF structure (byte order, IFD0, the Exif SubIFD) to pull five tags: Make, Model, Software, DateTime, and DateTimeOriginal/DateTimeDigitized. It is deliberately not a general TIFF library -- unrecognized tags and IFDs are skipped rather than decoded.

Every indicator this analyzer raises is a proxy, not proof: a `Software` tag naming an editor means the file passed through that editor at some point, not that it was used to deceive anyone. The weights in `MetadataAnalyzer.analyze` reflect that -- a suspicious software signature and an internally impossible timestamp order carry real weight, while a missing Make/Model tag (plenty of legitimate exports have none) is treated as a mild nudge, not a verdict on its own.

## Copy-move / clone detection (`Sources/ForensicLens/Analyzers/CloneDetectionAnalyzer.swift`)

The block-matching approach here is the classic block-based copy-move detection technique: slide a `blockSize` window across the image at `blockStride`, reduce each block to a coarse 4x4 grid of average brightness (cheap to compute, cheap to compare), and look for pairs of blocks whose feature vectors are close together and whose positions are far enough apart that they can't just be two overlapping samples of the same patch of sky.

The variance filter (`minimumBlockVariance`) is the single most important piece of this analyzer's precision. Flat regions -- a clear sky, a studio backdrop, an out-of-focus background -- are trivially "identical" to each other under any reasonable similarity metric, and without filtering them out first, they dominate the match list and bury any real finding in noise. Skipping low-variance blocks before comparison, rather than filtering matches afterward, keeps the comparison step itself proportional to the amount of actual detail in the image.

This implementation intentionally does not do shift-vector voting (clustering matches by a dominant `(dx, dy)` offset), which production copy-move detectors typically add to further suppress false positives from repetitive textures like brick or tile patterns. It's a reasonable next step if false positives on textured photos turn out to be a problem in practice, but it's extra machinery this project didn't need to prove the core technique out.

## Combining scores (`Sources/ForensicLens/Scoring/SuspicionScorer.swift`)

`SuspicionScorer` takes the strongest single analyzer score as the dominant signal and lets the others add a smaller, capped amount on top when they corroborate it, rather than averaging all three. A plain average would let one unambiguous finding (say, a 95 on clone detection) get diluted by two analyzers that simply had nothing to say about a small, EXIF-less BMP -- which isn't how a human reviewer would weigh the same evidence.
