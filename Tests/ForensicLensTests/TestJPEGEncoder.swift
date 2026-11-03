import Foundation
import ImageDecoding

/// A minimal baseline JPEG encoder for building test fixtures: standard
/// (ITU T.81 Annex K) quantization and Huffman tables scaled to a quality,
/// grayscale or YCbCr with 4:4:4 or 4:2:0 sampling, and optional restart
/// markers. Test-only: the package itself never writes JPEGs. Its output
/// was checked against an independent decoder (Windows' GDI+) while it was
/// written, so `BaselineJPEGDecoder` isn't only tested against itself.
enum TestJPEGEncoder {
    static func encode(_ buffer: PixelBuffer, quality: Int = 90, subsampled: Bool = false, restartInterval: Int = 0) -> [UInt8] {
        let width = buffer.width
        let height = buffer.height
        let color = buffer.channels >= 3
        let luminanceTable = scaled(luminanceQuant, quality: quality)
        let chrominanceTable = scaled(chrominanceQuant, quality: quality)

        var planes: [[Double]] = []
        if color {
            var y = [Double](repeating: 0, count: width * height)
            var cb = y
            var cr = y
            for i in 0..<(width * height) {
                let r = Double(buffer.pixels[i * buffer.channels])
                let g = Double(buffer.pixels[i * buffer.channels + 1])
                let b = Double(buffer.pixels[i * buffer.channels + 2])
                y[i] = 0.299 * r + 0.587 * g + 0.114 * b
                cb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                cr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
            }
            planes = [y, cb, cr]
        } else {
            planes = [buffer.pixels.map(Double.init)]
        }
        // (id, horizontal, vertical, table)
        let components: [(Int, Int, Int, Int)] = color
            ? [(1, subsampled ? 2 : 1, subsampled ? 2 : 1, 0), (2, 1, 1, 1), (3, 1, 1, 1)]
            : [(1, 1, 1, 0)]
        let maxH = components.map { $0.1 }.max() ?? 1
        let maxV = components.map { $0.2 }.max() ?? 1
        let mcusX = (width + 8 * maxH - 1) / (8 * maxH)
        let mcusY = (height + 8 * maxV - 1) / (8 * maxV)
        let quantTables = [luminanceTable, chrominanceTable]
        let dcCodes = [codes(dcLuminance), codes(dcChrominance)]
        let acCodes = [codes(acLuminance), codes(acChrominance)]

        func sample(_ component: Int, _ x: Int, _ y: Int) -> Double {
            let fx = maxH / components[component].1
            let fy = maxV / components[component].2
            var total = 0.0
            for dy in 0..<fy {
                for dx in 0..<fx {
                    total += planes[component][min(height - 1, y * fy + dy) * width + min(width - 1, x * fx + dx)]
                }
            }
            return total / Double(fx * fy)
        }

        var writer = BitWriter()
        var predictors = [Int](repeating: 0, count: components.count)
        var restartIndex = 0
        for mcu in 0..<(mcusX * mcusY) {
            if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
                writer.flush()
                writer.bytes.append(contentsOf: [0xFF, UInt8(0xD0 + restartIndex)])
                restartIndex = (restartIndex + 1) % 8
                predictors = [Int](repeating: 0, count: components.count)
            }
            let mcuX = mcu % mcusX
            let mcuY = mcu / mcusX
            for (index, component) in components.enumerated() {
                for blockY in 0..<component.2 {
                    for blockX in 0..<component.1 {
                        var block = [Double](repeating: 0, count: 64)
                        for y in 0..<8 {
                            for x in 0..<8 {
                                block[y * 8 + x] = sample(index, (mcuX * component.1 + blockX) * 8 + x, (mcuY * component.2 + blockY) * 8 + y) - 128
                            }
                        }
                        let coefficients = forwardDCT(block)
                        let table = quantTables[component.3]
                        let quantized = (0..<64).map { k -> Int in
                            let natural = zigzag[k]
                            return Int((coefficients[natural] / Double(table[natural])).rounded())
                        }
                        let difference = quantized[0] - predictors[index]
                        predictors[index] = quantized[0]
                        writeValue(difference, codes: dcCodes[component.3], symbolBase: 0, run: 0, into: &writer)
                        var run = 0
                        for k in 1..<64 {
                            let value = quantized[k]
                            if value == 0 { run += 1; continue }
                            while run > 15 {
                                write(acCodes[component.3][0xF0], into: &writer)
                                run -= 16
                            }
                            writeValue(value, codes: acCodes[component.3], symbolBase: run << 4, run: run, into: &writer)
                            run = 0
                        }
                        if run > 0 { write(acCodes[component.3][0x00], into: &writer) }
                    }
                }
            }
        }
        writer.flush()

        var out: [UInt8] = [0xFF, 0xD8]
        func segment(_ marker: UInt8, _ payload: [UInt8]) {
            out += [0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)]
            out += payload
        }
        segment(0xDB, [0] + (0..<64).map { UInt8(luminanceTable[zigzag[$0]]) })
        if color { segment(0xDB, [1] + (0..<64).map { UInt8(chrominanceTable[zigzag[$0]]) }) }
        var frame: [UInt8] = [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), UInt8(components.count)]
        for component in components { frame += [UInt8(component.0), UInt8(component.1 << 4 | component.2), UInt8(component.3)] }
        segment(0xC0, frame)
        var tables: [(UInt8, ([UInt8], [UInt8]))] = [(0x00, dcLuminance), (0x10, acLuminance)]
        if color { tables += [(0x01, dcChrominance), (0x11, acChrominance)] }
        for (id, spec) in tables { segment(0xC4, [id] + spec.0 + spec.1) }
        if restartInterval > 0 { segment(0xDD, [UInt8(restartInterval >> 8), UInt8(restartInterval & 0xFF)]) }
        var scan: [UInt8] = [UInt8(components.count)]
        for component in components { scan += [UInt8(component.0), UInt8(component.3 << 4 | component.3)] }
        segment(0xDA, scan + [0, 63, 0])
        out += writer.bytes
        out += [0xFF, 0xD9]
        return out
    }

    // MARK: - Pieces

    private struct BitWriter {
        var bytes: [UInt8] = []
        var accumulator = 0
        var count = 0

        mutating func write(_ value: Int, length: Int) {
            for i in stride(from: length - 1, through: 0, by: -1) {
                accumulator = (accumulator << 1) | ((value >> i) & 1)
                count += 1
                if count == 8 {
                    bytes.append(UInt8(accumulator))
                    if accumulator == 0xFF { bytes.append(0) }
                    accumulator = 0
                    count = 0
                }
            }
        }

        mutating func flush() {
            if count > 0 { write((1 << (8 - count)) - 1, length: 8 - count) }
        }
    }

    private static func category(_ value: Int) -> Int {
        var magnitude = abs(value)
        var bits = 0
        while magnitude > 0 { bits += 1; magnitude >>= 1 }
        return bits
    }

    private static func write(_ code: (Int, Int)?, into writer: inout BitWriter) {
        guard let code else { return }
        writer.write(code.0, length: code.1)
    }

    private static func writeValue(_ value: Int, codes: [Int: (Int, Int)], symbolBase: Int, run: Int, into writer: inout BitWriter) {
        let size = category(value)
        write(codes[symbolBase | size], into: &writer)
        if size > 0 { writer.write(value > 0 ? value : value + (1 << size) - 1, length: size) }
    }

    private static func codes(_ spec: ([UInt8], [UInt8])) -> [Int: (Int, Int)] {
        var result: [Int: (Int, Int)] = [:]
        var code = 0
        var k = 0
        for length in 1...16 {
            for _ in 0..<Int(spec.0[length - 1]) {
                result[Int(spec.1[k])] = (code, length)
                code += 1
                k += 1
            }
            code <<= 1
        }
        return result
    }

    private static func scaled(_ table: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        return table.map { max(1, min(255, ($0 * scale + 50) / 100)) }
    }

    private static func forwardDCT(_ block: [Double]) -> [Double] {
        var rows = [Double](repeating: 0, count: 64)
        for y in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for x in 0..<8 { sum += block[y * 8 + x] * cosines[x * 8 + u] }
                rows[y * 8 + u] = sum
            }
        }
        var output = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for y in 0..<8 { sum += rows[y * 8 + u] * cosines[y * 8 + v] }
                output[v * 8 + u] = sum
            }
        }
        return output
    }

    /// `C(u) * cos((2x + 1) * u * pi / 16) / 2`, the same normalization the
    /// decoder's inverse uses.
    private static let cosines: [Double] = (0..<64).map { index in
        let x = index / 8
        let u = index % 8
        return (u == 0 ? 1 / 2.0.squareRoot() : 1) * cos(Double(2 * x + 1) * Double(u) * Double.pi / 16) / 2
    }

    /// Zigzag position -> natural index; deliberately its own copy rather
    /// than the decoder's, so a mistake there can't hide in both.
    private static let zigzag = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    private static let luminanceQuant = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    private static let chrominanceQuant = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99]
        + [Int](repeating: 99, count: 32)

    private static let dcLuminance: ([UInt8], [UInt8]) = ([0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], Array(0...11))
    private static let dcChrominance: ([UInt8], [UInt8]) = ([0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], Array(0...11))
    private static let acLuminance: ([UInt8], [UInt8]) = ([0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D], [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
    ])
    private static let acChrominance: ([UInt8], [UInt8]) = ([0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
    ])
}
