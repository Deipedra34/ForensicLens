# Algorithm notes

A deeper look at how each analyzer actually works, mostly for whoever ends up extending or auditing them later. The short version of each lives in doc comments right above the relevant type in the source; this file just has more room to get into the "why" without cluttering that up.

## Error Level Analysis (`Sources/ForensicLens/Analyzers/ELAAnalyzer.swift`)

ForensicLens doesn't carry a real JPEG encoder, so ELA can't literally re-save a JPEG file the way you'd expect. What `JPEGRecompressionSimulator` does instead is perform the one lossy step that actually matters — level shift, 8x8 block DCT, quantize at the configured quality, dequantize, inverse DCT — directly against the decoded `PixelBuffer`. That's the exact operation a real encoder's lossy stage performs. Skipping entropy coding and the container format doesn't change the error signature ELA is looking for, and as a bonus the analyzer ends up working identically on every format the package can decode, not just JPEG.

The DCT itself (`DCT8x8`) is a plain, separable implementation with a precomputed cosine table. There's not much to gain from an FFT-based transform at a fixed 8x8 block size, and honestly a direct implementation is a lot easier to check by hand for correctness.

Two config knobs really shape the result here. `qualityLevel` controls how aggressively the quantization tables round coefficients toward zero — this is the classic ELA sensitivity/noise trade-off, where coarser quantization (lower quality) makes genuine edits stand out more but also makes untouched high-frequency content like edges and text noisier. `errorThreshold` and `flaggedRegionFraction`, meanwhile, control how the per-pixel error map turns into a small number of reported "regions": the map gets bucketed into 16x16 reporting cells, and a cell counts as "hot" once its mean error crosses the threshold.

## EXIF / metadata analysis (`Sources/ForensicLens/Analyzers/MetadataAnalyzer.swift`)

EXIF lives in a JPEG's `APP1` marker segment, which sits in the file header before any compressed pixel data even starts. That means this analyzer never needs a working JPEG pixel decoder — `ExifReader` just walks the JPEG's marker segments looking for `APP1` with an `Exif\0\0` preamble, then parses just enough of the embedded TIFF structure (byte order, IFD0, the Exif SubIFD) to pull five tags: Make, Model, Software, DateTime, and DateTimeOriginal/DateTimeDigitized. It's not a general TIFF library by any means; unrecognized tags and IFDs just get skipped rather than decoded.

Worth keeping in mind: every indicator this analyzer raises is a proxy, not proof. A `Software` tag naming an editor means the file passed through that editor at some point — it doesn't mean anyone used it to deceive someone. The weights in `MetadataAnalyzer.analyze` try to reflect that: a suspicious software signature and an internally impossible timestamp order carry real weight, while a missing Make/Model tag (plenty of legitimate exports have none at all) is treated as a mild nudge rather than a verdict on its own.

## Copy-move / clone detection (`Sources/ForensicLens/Analyzers/CloneDetectionAnalyzer.swift`)

The block-matching here is the classic approach to block-based copy-move detection: slide a `blockSize` window across the image at `blockStride`, reduce each block to a coarse 4x4 grid of average brightness (cheap to compute, cheap to compare), then look for pairs of blocks whose feature vectors are close together and whose positions are far enough apart that they can't just be two overlapping samples of the same patch of sky.

If there's one piece of this analyzer that matters most for precision, it's the variance filter (`minimumBlockVariance`). Flat regions — a clear sky, a studio backdrop, an out-of-focus background — are trivially "identical" to each other under pretty much any similarity metric, and without filtering them out first they'd dominate the match list and bury any real finding in noise. Skipping low-variance blocks before comparison, rather than filtering matches after the fact, also keeps the comparison step itself roughly proportional to how much actual detail is in the image.

One thing this implementation doesn't do is shift-vector voting — clustering matches by a dominant `(dx, dy)` offset, which production copy-move detectors usually add to suppress false positives from repetitive textures like brick or tile patterns. That's a reasonable thing to add later if false positives on textured photos turn out to be a real problem, but it felt like extra machinery this project didn't need just to prove the core technique out.

## Combining scores (`Sources/ForensicLens/Scoring/SuspicionScorer.swift`)

`SuspicionScorer` takes the strongest single analyzer score as the dominant signal and lets the other two add a smaller, capped amount on top when they back it up, rather than just averaging all three. A plain average would let one unambiguous finding (say, a 95 on clone detection) get diluted by two analyzers that simply had nothing to say about a small, EXIF-less BMP — and that's not really how a human reviewer would weigh the same pile of evidence anyway.
