import Foundation

/// Errors from `BaselineJPEGDecoder`.
public enum JPEGDecodingError: Error, Equatable, CustomStringConvertible {
    /// The bytes don't start with a JPEG start-of-image marker.
    case notJPEG
    /// The data ends (or a marker interrupts the entropy-coded data) before
    /// the whole image has been decoded.
    case truncated
    /// A valid JPEG feature this decoder doesn't implement, such as
    /// progressive or arithmetic coding.
    case unsupported(String)
    /// Malformed data: a bad table, an invalid Huffman code, a missing
    /// restart marker.
    case corrupt(String)

    public var description: String {
        switch self {
        case .notJPEG: return "Not a JPEG (no start-of-image marker)."
        case .truncated: return "The JPEG data is truncated."
        case .unsupported(let detail): return "Unsupported JPEG variant: \(detail)."
        case .corrupt(let detail): return "Corrupt JPEG data: \(detail)."
        }
    }
}

/// A small, self-contained baseline JPEG decoder.
///
/// It handles the JPEGs cameras and phones write for photos and their EXIF
/// thumbnails: baseline and extended sequential DCT (SOF0/SOF1), 8-bit
/// samples, Huffman coding, one (grayscale) or three (YCbCr, or RGB per an
/// Adobe marker) components, any chroma subsampling, and restart markers.
/// Progressive, lossless, hierarchical and arithmetic-coded JPEGs, 12-bit
/// samples, CMYK, and multi-scan sequential files throw `.unsupported`.
/// Anything malformed or cut short throws, rather than returning a
/// half-decoded image that would look like real content. Chroma is upsampled
/// by nearest neighbor. That's slightly blockier than a decoder with
/// smoothing filters, but every analysis that uses this decoder reads
/// luminance, which is never subsampled.
///
/// `scale: .eighth` decodes only each 8x8 block's DC coefficient (its mean),
/// skipping every inverse DCT and returning a 1/8-size image. That's the
/// classic fast path for previews: the entropy-coded data still has to be
/// read in full, but the output costs a fraction of a full decode.
///
/// **Not used by `ImageData.load`.** `ImageDecoder` still reports JPEG
/// pixel decoding as not implemented, so the pixel analyzers (ELA, clone,
/// PRNU, CFA, JPEG ghost) keep treating JPEG input as metadata-only.
/// Feeding them decoded JPEG pixels is a separate decision with visible
/// effects on every JPEG's score. Today this decoder serves EXIF thumbnail
/// consistency checking, which needs both the embedded thumbnail and a
/// downscaled copy of the main image.
public enum BaselineJPEGDecoder {
    public enum Scale: Sendable {
        case full
        /// One output pixel per 8x8 block (block means, no inverse DCT).
        case eighth
    }

    public enum Output: Sendable {
        /// RGB (three channels), or one channel for a grayscale JPEG.
        case color
        /// One channel: the luminance (`Y`) plane.
        case luminance
    }

    /// The frame header's size and component count.
    public struct FrameInfo: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let components: Int

        public init(width: Int, height: Int, components: Int) {
            self.width = width
            self.height = height
            self.components = components
        }
    }

    /// Images larger than this many pixels are refused rather than decoded,
    /// to keep a hostile or corrupt header from requesting gigabytes.
    public static let maximumPixelCount = 1 << 28

    /// Reads only the headers, up to the frame header.
    public static func frameInfo(_ data: [UInt8]) throws -> FrameInfo {
        let header = try parseHeaders(data, stopAtFrame: true)
        guard let frame = header.frame else { throw JPEGDecodingError.corrupt("no frame header") }
        return FrameInfo(width: frame.width, height: frame.height, components: frame.components.count)
    }

    public static func decode(_ data: [UInt8], scale: Scale = .full, output: Output = .color) throws -> PixelBuffer {
        let header = try parseHeaders(data, stopAtFrame: false)
        guard let frame = header.frame, let scan = header.scan else { throw JPEGDecodingError.corrupt("no frame or scan") }
        var decoder = try ScanDecoder(data: data, header: header, frame: frame, scan: scan, scale: scale, output: output)
        return try decoder.run()
    }

    // MARK: - Headers

    struct Component {
        let id: Int
        let horizontal: Int
        let vertical: Int
        let quantTable: Int
    }

    struct Frame {
        let width: Int
        let height: Int
        let components: [Component]
    }

    struct ScanComponent {
        let index: Int
        let dcTable: Int
        let acTable: Int
    }

    struct Scan {
        let components: [ScanComponent]
        let dataStart: Int
    }

    struct Header {
        var quantTables: [Int: [Int]] = [:]
        var dcTables: [Int: HuffmanTable] = [:]
        var acTables: [Int: HuffmanTable] = [:]
        var frame: Frame?
        var scan: Scan?
        var restartInterval = 0
        var adobeTransform: Int?
    }

    static func parseHeaders(_ data: [UInt8], stopAtFrame: Bool) throws -> Header {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { throw JPEGDecodingError.notJPEG }
        var header = Header()
        var position = 2

        while true {
            // Skip anything up to the next marker, then any fill bytes.
            while position < data.count && data[position] != 0xFF { position += 1 }
            while position < data.count && data[position] == 0xFF { position += 1 }
            guard position < data.count else { throw JPEGDecodingError.truncated }
            let marker = data[position]
            position += 1

            if marker == 0xD9 { throw JPEGDecodingError.corrupt("end of image before any scan") }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { continue }

            guard position + 2 <= data.count else { throw JPEGDecodingError.truncated }
            let length = Int(data[position]) << 8 | Int(data[position + 1])
            guard length >= 2, position + length <= data.count else { throw JPEGDecodingError.truncated }
            let segment = Array(data[(position + 2)..<(position + length)])
            position += length

            switch marker {
            case 0xDB:
                try parseQuantTables(segment, into: &header)
            case 0xC4:
                try parseHuffmanTables(segment, into: &header)
            case 0xC0, 0xC1:
                header.frame = try parseFrame(segment)
                if stopAtFrame { return header }
            case 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                throw JPEGDecodingError.unsupported(marker == 0xC2 || marker == 0xC6 || marker == 0xCA || marker == 0xCE ? "progressive JPEG" : "lossless, hierarchical, or arithmetic-coded JPEG")
            case 0xDD:
                guard segment.count >= 2 else { throw JPEGDecodingError.corrupt("short restart interval segment") }
                header.restartInterval = Int(segment[0]) << 8 | Int(segment[1])
            case 0xEE:
                if segment.count >= 12, Array(segment[0..<5]) == Array("Adobe".utf8) {
                    header.adobeTransform = Int(segment[11])
                }
            case 0xDA:
                guard let frame = header.frame else { throw JPEGDecodingError.corrupt("scan before frame header") }
                header.scan = try parseScan(segment, frame: frame, dataStart: position)
                return header
            default:
                continue // APPn, COM, and anything else with a length: skip.
            }
        }
    }

    private static func parseQuantTables(_ segment: [UInt8], into header: inout Header) throws {
        var index = 0
        while index < segment.count {
            let precision = Int(segment[index] >> 4)
            let id = Int(segment[index] & 0x0F)
            index += 1
            let size = precision == 0 ? 64 : 128
            guard precision <= 1, index + size <= segment.count else { throw JPEGDecodingError.corrupt("bad quantization table") }
            var table = [Int](repeating: 0, count: 64)
            for k in 0..<64 {
                let value = precision == 0 ? Int(segment[index + k]) : Int(segment[index + 2 * k]) << 8 | Int(segment[index + 2 * k + 1])
                table[zigzag[k]] = value
            }
            header.quantTables[id] = table
            index += size
        }
    }

    private static func parseHuffmanTables(_ segment: [UInt8], into header: inout Header) throws {
        var index = 0
        while index < segment.count {
            guard index + 17 <= segment.count else { throw JPEGDecodingError.corrupt("bad Huffman table") }
            let tableClass = Int(segment[index] >> 4)
            let id = Int(segment[index] & 0x0F)
            let counts = segment[(index + 1)..<(index + 17)].map(Int.init)
            let total = counts.reduce(0, +)
            guard tableClass <= 1, total <= 256, index + 17 + total <= segment.count else { throw JPEGDecodingError.corrupt("bad Huffman table") }
            let symbols = Array(segment[(index + 17)..<(index + 17 + total)])
            let table = try HuffmanTable(counts: counts, symbols: symbols)
            if tableClass == 0 { header.dcTables[id] = table } else { header.acTables[id] = table }
            index += 17 + total
        }
    }

    private static func parseFrame(_ segment: [UInt8]) throws -> Frame {
        guard segment.count >= 6 else { throw JPEGDecodingError.corrupt("short frame header") }
        guard segment[0] == 8 else { throw JPEGDecodingError.unsupported("\(segment[0])-bit samples") }
        let height = Int(segment[1]) << 8 | Int(segment[2])
        let width = Int(segment[3]) << 8 | Int(segment[4])
        let count = Int(segment[5])
        guard width > 0, height > 0 else { throw JPEGDecodingError.unsupported("image height defined after the scan (DNL)") }
        guard width * height <= maximumPixelCount else { throw JPEGDecodingError.unsupported("image larger than \(maximumPixelCount) pixels") }
        guard count == 1 || count == 3 else { throw JPEGDecodingError.unsupported("\(count) color components") }
        guard segment.count >= 6 + 3 * count else { throw JPEGDecodingError.corrupt("short frame header") }
        var components: [Component] = []
        for c in 0..<count {
            let base = 6 + 3 * c
            let horizontal = Int(segment[base + 1] >> 4)
            let vertical = Int(segment[base + 1] & 0x0F)
            guard (1...4).contains(horizontal), (1...4).contains(vertical) else { throw JPEGDecodingError.corrupt("bad sampling factors") }
            components.append(Component(id: Int(segment[base]), horizontal: horizontal, vertical: vertical, quantTable: Int(segment[base + 2])))
        }
        return Frame(width: width, height: height, components: components)
    }

    private static func parseScan(_ segment: [UInt8], frame: Frame, dataStart: Int) throws -> Scan {
        guard let count = segment.first.map(Int.init), segment.count >= 1 + 2 * count + 3 else { throw JPEGDecodingError.corrupt("short scan header") }
        var components: [ScanComponent] = []
        for k in 0..<count {
            let id = Int(segment[1 + 2 * k])
            let tables = segment[2 + 2 * k]
            guard let index = frame.components.firstIndex(where: { $0.id == id }) else { throw JPEGDecodingError.corrupt("scan names an unknown component") }
            components.append(ScanComponent(index: index, dcTable: Int(tables >> 4), acTable: Int(tables & 0x0F)))
        }
        let spectralStart = segment[1 + 2 * count]
        let spectralEnd = segment[2 + 2 * count]
        let approximation = segment[3 + 2 * count]
        guard spectralStart == 0, spectralEnd == 63, approximation == 0 else { throw JPEGDecodingError.unsupported("progressive scan") }
        guard components.count == frame.components.count else { throw JPEGDecodingError.unsupported("multi-scan sequential JPEG") }
        return Scan(components: components, dataStart: dataStart)
    }

    // MARK: - Huffman

    struct HuffmanTable {
        // Canonical decoding tables (ITU T.81 Annex F.2.2.3), indexed by code length 1...16.
        var maxCode = [Int](repeating: -1, count: 18)
        var valuePointer = [Int](repeating: 0, count: 17)
        var minCode = [Int](repeating: 0, count: 17)
        let symbols: [UInt8]

        init(counts: [Int], symbols: [UInt8]) throws {
            self.symbols = symbols
            var code = 0
            var k = 0
            for length in 1...16 {
                let count = counts[length - 1]
                if count > 0 {
                    valuePointer[length] = k
                    minCode[length] = code
                    code += count
                    k += count
                    maxCode[length] = code - 1
                    guard code <= (1 << length) else { throw JPEGDecodingError.corrupt("over-subscribed Huffman table") }
                }
                code <<= 1
            }
            maxCode[17] = Int.max
        }
    }

    // MARK: - Entropy-coded data

    struct BitReader {
        let data: [UInt8]
        var position: Int
        var buffer: UInt32 = 0
        var bitCount = 0
        /// A marker reached inside the entropy-coded data; `position` points at its 0xFF.
        var marker: UInt8?

        init(data: [UInt8], position: Int) {
            self.data = data
            self.position = position
        }

        mutating func bit() throws -> Int {
            if bitCount == 0 {
                guard marker == nil, position < data.count else { throw JPEGDecodingError.truncated }
                let byte = data[position]
                if byte == 0xFF {
                    guard position + 1 < data.count else { throw JPEGDecodingError.truncated }
                    let next = data[position + 1]
                    guard next == 0x00 else {
                        marker = next
                        throw JPEGDecodingError.truncated
                    }
                    position += 2
                } else {
                    position += 1
                }
                buffer = UInt32(byte)
                bitCount = 8
            }
            bitCount -= 1
            return Int((buffer >> UInt32(bitCount)) & 1)
        }

        mutating func bits(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count { value = (value << 1) | (try bit()) }
            return value
        }

        mutating func decode(_ table: HuffmanTable) throws -> Int {
            var code = try bit()
            var length = 1
            while code > table.maxCode[length] {
                code = (code << 1) | (try bit())
                length += 1
                guard length <= 16 else { throw JPEGDecodingError.corrupt("invalid Huffman code") }
            }
            let index = table.valuePointer[length] + code - table.minCode[length]
            guard index >= 0, index < table.symbols.count else { throw JPEGDecodingError.corrupt("invalid Huffman code") }
            return Int(table.symbols[index])
        }

        /// Skips to just after the restart marker that must come next,
        /// discarding the padding bits before it.
        mutating func consumeRestartMarker() throws {
            buffer = 0
            bitCount = 0
            if let marker {
                guard (0xD0...0xD7).contains(marker) else { throw JPEGDecodingError.corrupt("expected a restart marker") }
                self.marker = nil
                position += 2
                return
            }
            guard position + 1 < data.count, data[position] == 0xFF, (0xD0...0xD7).contains(data[position + 1]) else {
                throw JPEGDecodingError.corrupt("expected a restart marker")
            }
            position += 2
        }
    }

    /// Sign-extends a `size`-bit magnitude category value (T.81 F.2.2.1).
    static func extend(_ value: Int, size: Int) -> Int {
        guard size > 0 else { return 0 }
        return value < (1 << (size - 1)) ? value - (1 << size) + 1 : value
    }

    // MARK: - Decoding

    private struct ScanDecoder {
        let header: Header
        let frame: Frame
        let scan: Scan
        let scale: Scale
        let output: Output
        var reader: BitReader
        let maxHorizontal: Int
        let maxVertical: Int
        let mcusPerLine: Int
        let mcusPerColumn: Int
        let blockSide: Int
        /// Per frame component: sample plane, its width in samples, and
        /// whether it's needed for the requested output at all.
        var planes: [[UInt8]]
        let planeWidths: [Int]
        let needed: [Bool]

        init(data: [UInt8], header: Header, frame: Frame, scan: Scan, scale: Scale, output: Output) throws {
            self.header = header
            self.frame = frame
            self.scan = scan
            self.scale = scale
            self.output = output
            reader = BitReader(data: data, position: scan.dataStart)

            // A single-component scan is never interleaved: its blocks run
            // row by row, whatever sampling factors the frame declared.
            let single = frame.components.count == 1
            maxHorizontal = single ? 1 : frame.components.map(\.horizontal).max() ?? 1
            maxVertical = single ? 1 : frame.components.map(\.vertical).max() ?? 1
            mcusPerLine = (frame.width + 8 * maxHorizontal - 1) / (8 * maxHorizontal)
            mcusPerColumn = (frame.height + 8 * maxVertical - 1) / (8 * maxVertical)
            blockSide = scale == .full ? 8 : 1

            let rgbComponents = frame.components.count == 3 && header.adobeTransform == 0
            var planes: [[UInt8]] = []
            var widths: [Int] = []
            var needed: [Bool] = []
            for (index, component) in frame.components.enumerated() {
                let horizontal = single ? 1 : component.horizontal
                let vertical = single ? 1 : component.vertical
                let width = mcusPerLine * horizontal * blockSide
                let height = mcusPerColumn * vertical * blockSide
                let isNeeded = output == .color || index == 0 || rgbComponents
                planes.append(isNeeded ? [UInt8](repeating: 0, count: width * height) : [])
                widths.append(width)
                needed.append(isNeeded)
                guard header.quantTables[component.quantTable] != nil else { throw JPEGDecodingError.corrupt("missing quantization table") }
            }
            self.planes = planes
            planeWidths = widths
            self.needed = needed
            for component in scan.components {
                guard header.dcTables[component.dcTable] != nil, header.acTables[component.acTable] != nil else {
                    throw JPEGDecodingError.corrupt("missing Huffman table")
                }
            }
        }

        mutating func run() throws -> PixelBuffer {
            let single = frame.components.count == 1
            var predictors = [Int](repeating: 0, count: frame.components.count)
            var coefficients = [Int](repeating: 0, count: 64)
            let total = mcusPerLine * mcusPerColumn

            for mcu in 0..<total {
                if header.restartInterval > 0, mcu > 0, mcu % header.restartInterval == 0 {
                    try reader.consumeRestartMarker()
                    for i in predictors.indices { predictors[i] = 0 }
                }
                let mcuX = mcu % mcusPerLine
                let mcuY = mcu / mcusPerLine
                for scanComponent in scan.components {
                    let index = scanComponent.index
                    let component = frame.components[index]
                    let horizontal = single ? 1 : component.horizontal
                    let vertical = single ? 1 : component.vertical
                    // Checked in `init`.
                    guard let dcTable = header.dcTables[scanComponent.dcTable],
                          let acTable = header.acTables[scanComponent.acTable],
                          let quant = header.quantTables[component.quantTable]
                    else { throw JPEGDecodingError.corrupt("missing table") }

                    for blockY in 0..<vertical {
                        for blockX in 0..<horizontal {
                            // DC coefficient: a difference from the previous block's.
                            let size = try reader.decode(dcTable)
                            guard size <= 11 else { throw JPEGDecodingError.corrupt("bad DC coefficient") }
                            predictors[index] += BaselineJPEGDecoder.extend(try reader.bits(size), size: size)

                            // AC coefficients, run-length coded; read them
                            // all even when only the DC is kept.
                            for i in 1..<64 { coefficients[i] = 0 }
                            coefficients[0] = predictors[index]
                            var k = 1
                            while k < 64 {
                                let symbol = try reader.decode(acTable)
                                let run = symbol >> 4
                                let size = symbol & 0x0F
                                if size == 0 {
                                    if run == 15 { k += 16; continue }
                                    break
                                }
                                k += run
                                guard k <= 63 else { throw JPEGDecodingError.corrupt("AC coefficients past the end of a block") }
                                let value = BaselineJPEGDecoder.extend(try reader.bits(size), size: size)
                                if scale == .full { coefficients[zigzag[k]] = value }
                                k += 1
                            }

                            guard needed[index] else { continue }
                            let blockColumn = mcuX * horizontal + blockX
                            let blockRow = mcuY * vertical + blockY
                            store(coefficients, quant: quant, component: index, column: blockColumn, row: blockRow)
                        }
                    }
                }
            }
            return try assemble()
        }

        private mutating func store(_ coefficients: [Int], quant: [Int], component: Int, column: Int, row: Int) {
            let width = planeWidths[component]
            if scale == .eighth {
                // The DC coefficient is 8x the block mean (T.81's DCT scaling).
                let mean = Double(coefficients[0] * quant[0]) / 8 + 128
                planes[component][row * width + column] = UInt8(clamping: Int(mean.rounded()))
                return
            }
            var dequantized = [Double](repeating: 0, count: 64)
            for i in 0..<64 { dequantized[i] = Double(coefficients[i] * quant[i]) }
            let samples = InverseDCT.transform(dequantized)
            for y in 0..<8 {
                let rowStart = (row * 8 + y) * width + column * 8
                for x in 0..<8 {
                    planes[component][rowStart + x] = UInt8(clamping: Int((samples[y * 8 + x] + 128).rounded()))
                }
            }
        }

        private func assemble() throws -> PixelBuffer {
            let divisor = scale == .full ? 1 : 8
            let width = (frame.width + divisor - 1) / divisor
            let height = (frame.height + divisor - 1) / divisor
            let single = frame.components.count == 1

            func sample(_ component: Int, _ x: Int, _ y: Int) -> Int {
                let c = frame.components[component]
                let horizontal = single ? 1 : c.horizontal
                let vertical = single ? 1 : c.vertical
                let planeX = x * horizontal / maxHorizontal
                let planeY = y * vertical / maxVertical
                return Int(planes[component][planeY * planeWidths[component] + planeX])
            }

            let rgbComponents = frame.components.count == 3 && header.adobeTransform == 0
            if single || (output == .luminance && !rgbComponents) {
                var pixels = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width { pixels[y * width + x] = UInt8(sample(0, x, y)) }
                }
                return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
            }

            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            var luma = output == .luminance ? [UInt8](repeating: 0, count: width * height) : []
            for y in 0..<height {
                for x in 0..<width {
                    let first = Double(sample(0, x, y))
                    let second = Double(sample(1, x, y))
                    let third = Double(sample(2, x, y))
                    let r: Double, g: Double, b: Double
                    if rgbComponents {
                        (r, g, b) = (first, second, third)
                    } else {
                        let cb = second - 128
                        let cr = third - 128
                        r = first + 1.402 * cr
                        g = first - 0.344136 * cb - 0.714136 * cr
                        b = first + 1.772 * cb
                    }
                    let i = y * width + x
                    if output == .luminance {
                        luma[i] = UInt8(clamping: Int((0.299 * r + 0.587 * g + 0.114 * b).rounded()))
                    } else {
                        rgb[i * 3] = UInt8(clamping: Int(r.rounded()))
                        rgb[i * 3 + 1] = UInt8(clamping: Int(g.rounded()))
                        rgb[i * 3 + 2] = UInt8(clamping: Int(b.rounded()))
                    }
                }
            }
            if output == .luminance {
                return try PixelBuffer(width: width, height: height, channels: 1, pixels: luma)
            }
            return try PixelBuffer(width: width, height: height, channels: 3, pixels: rgb)
        }
    }

    /// Zigzag scan position -> natural (row-major) coefficient index.
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]
}

/// The 8x8 inverse DCT (T.81 A.3.3), separable, with a precomputed cosine
/// table.
enum InverseDCT {
    /// `cosines[x * 8 + u] == C(u) * cos((2x + 1) * u * pi / 16) / 2`, so
    /// one pass over rows and one over columns give the full transform.
    private static let cosines: [Double] = {
        var table = [Double](repeating: 0, count: 64)
        for x in 0..<8 {
            for u in 0..<8 {
                let c: Double = u == 0 ? 1 / 2.0.squareRoot() : 1
                table[x * 8 + u] = c * cos(Double(2 * x + 1) * Double(u) * Double.pi / 16) / 2
            }
        }
        return table
    }()

    static func transform(_ coefficients: [Double]) -> [Double] {
        var rows = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            for x in 0..<8 {
                var sum = 0.0
                for u in 0..<8 { sum += cosines[x * 8 + u] * coefficients[v * 8 + u] }
                rows[v * 8 + x] = sum
            }
        }
        var samples = [Double](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<8 {
                var sum = 0.0
                for v in 0..<8 { sum += cosines[y * 8 + v] * rows[v * 8 + x] }
                samples[y * 8 + x] = sum
            }
        }
        return samples
    }
}
