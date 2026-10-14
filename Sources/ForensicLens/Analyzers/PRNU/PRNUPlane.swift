import ImageDecoding

/// A single-channel grid of `Double` samples: a luminance channel, a noise
/// residual, a wavelet coefficient layout, or a sensor fingerprint.
///
/// PRNU analysis works on signals a fraction of a gray level in size, so
/// none of it can live in `PixelBuffer`'s `UInt8` channels without
/// rounding the very signal being measured away. Every PRNU stage passes
/// this type around instead. `values` is row-major and always holds exactly
/// `width * height` samples; every initializer below maintains that.
struct PRNUPlane: Sendable, Equatable {
    let width: Int
    let height: Int
    var values: [Double]

    /// Wraps `values` as a `width` x `height` plane. If the count doesn't
    /// match, the plane is padded with zeros or truncated to fit rather
    /// than trapping, though no caller in this package ever passes a
    /// mismatched array.
    init(width: Int, height: Int, values: [Double]) {
        let width = max(0, width)
        let height = max(0, height)
        let count = width * height
        self.width = width
        self.height = height
        if values.count == count {
            self.values = values
        } else if values.count > count {
            self.values = Array(values[0..<count])
        } else {
            self.values = values + [Double](repeating: 0, count: count - values.count)
        }
    }

    init(width: Int, height: Int, repeating value: Double = 0) {
        self.init(width: width, height: height, values: [Double](repeating: value, count: max(0, width) * max(0, height)))
    }

    subscript(x: Int, y: Int) -> Double {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    /// The image's luminance as unrounded Rec. 601 luma (the same
    /// coefficients `PixelBuffer.luma` uses). `PixelBuffer.luma` itself
    /// rounds to a whole gray level, which would add a quantization step
    /// on top of the sensor noise this analysis is trying to isolate. A
    /// buffer with fewer than three channels is read from its first
    /// channel, the same way `PixelBuffer.luma` treats grayscale.
    static func luminance(of buffer: PixelBuffer) -> PRNUPlane {
        let count = buffer.width * buffer.height
        let channels = buffer.channels
        let pixels = buffer.pixels
        var values = [Double](repeating: 0, count: count)
        if channels >= 3 {
            for i in 0..<count {
                let base = i * channels
                values[i] = 0.299 * Double(pixels[base]) + 0.587 * Double(pixels[base + 1]) + 0.114 * Double(pixels[base + 2])
            }
        } else {
            for i in 0..<count {
                values[i] = Double(pixels[i * channels])
            }
        }
        return PRNUPlane(width: buffer.width, height: buffer.height, values: values)
    }

    /// The sub-rectangle `region`, clipped to this plane's bounds. An empty
    /// or fully out-of-bounds region gives an empty (0 x 0) plane.
    func cropped(to region: Region) -> PRNUPlane {
        let x0 = max(0, region.x)
        let y0 = max(0, region.y)
        let x1 = min(width, region.x + region.width)
        let y1 = min(height, region.y + region.height)
        guard x1 > x0, y1 > y0 else { return PRNUPlane(width: 0, height: 0) }

        let croppedWidth = x1 - x0
        var values = [Double]()
        values.reserveCapacity(croppedWidth * (y1 - y0))
        for y in y0..<y1 {
            let rowStart = y * width
            values.append(contentsOf: self.values[(rowStart + x0)..<(rowStart + x1)])
        }
        return PRNUPlane(width: croppedWidth, height: y1 - y0, values: values)
    }

    /// Averages every `factor` x `factor` cell into one sample: a box
    /// downsample by an integer factor, dropping any partial cell at the
    /// right and bottom edges. `factor <= 1` returns the plane unchanged.
    ///
    /// Box averaging is the gentlest downsample for noise analysis: it
    /// scales independent noise down by the same factor everywhere, so the
    /// *relative* noise structure the local consistency check compares
    /// between blocks survives, unlike an interpolating resampler that
    /// would mix neighboring samples by position-dependent weights.
    func downsampled(by factor: Int) -> PRNUPlane {
        guard factor > 1 else { return self }
        let newWidth = width / factor
        let newHeight = height / factor
        guard newWidth > 0, newHeight > 0 else { return PRNUPlane(width: 0, height: 0) }

        var output = [Double](repeating: 0, count: newWidth * newHeight)
        let cellArea = Double(factor * factor)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                var sum = 0.0
                for dy in 0..<factor {
                    let rowStart = (y * factor + dy) * width + x * factor
                    for dx in 0..<factor {
                        sum += values[rowStart + dx]
                    }
                }
                output[y * newWidth + x] = sum / cellArea
            }
        }
        return PRNUPlane(width: newWidth, height: newHeight, values: output)
    }

    /// This plane extended to `newWidth` x `newHeight` by mirror
    /// reflection about its right and bottom edges (`... c b a | a b c ...`),
    /// repeating the reflection if the requested size is more than double
    /// the original. Mirroring rather than zero-filling keeps the padded
    /// border free of an artificial step edge, which a denoiser would
    /// otherwise partly leave behind in the noise residual.
    func mirrorPadded(toWidth newWidth: Int, height newHeight: Int) -> PRNUPlane {
        guard width > 0, height > 0, newWidth >= width, newHeight >= height else { return self }
        guard newWidth != width || newHeight != height else { return self }

        func reflect(_ index: Int, _ count: Int) -> Int {
            let period = 2 * count
            let m = index % period
            return m < count ? m : period - 1 - m
        }

        var output = [Double](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let sourceRow = reflect(y, height) * width
            for x in 0..<newWidth {
                output[y * newWidth + x] = values[sourceRow + reflect(x, width)]
            }
        }
        return PRNUPlane(width: newWidth, height: newHeight, values: output)
    }
}
