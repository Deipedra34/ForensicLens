#if os(WASI)
/// The functions the WebAssembly module exports to JavaScript.
///
/// Only numbers cross the boundary, as plain C-ABI parameters: lengths and
/// addresses in the module's linear memory. To pass bytes in, the page
/// calls `forensiclens_alloc`, copies its data into that memory, passes the
/// address and length, and frees it afterward. Every result is a buffer
/// laid out as a 4-byte little-endian length followed by that many bytes of
/// UTF-8 JSON (see `WebAnalysisAPI`). The page reads it and hands it back to
/// `forensiclens_free`. A `nil` (0) result means allocation failed.
///
/// `@_expose(wasm, ...)` names each function in the module's export
/// table, and `@_cdecl` gives it a plain C calling convention. The file is
/// compiled only for WASI, so a native build of this package never sees it.

@_expose(wasm, "forensiclens_alloc")
@_cdecl("forensiclens_alloc")
func forensiclensAlloc(_ byteCount: Int32) -> UnsafeMutableRawPointer? {
    guard byteCount >= 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(byteCount)), alignment: 16)
}

@_expose(wasm, "forensiclens_free")
@_cdecl("forensiclens_free")
func forensiclensFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// JSON array of `{id, name}` for every analyzer, in run order.
@_expose(wasm, "forensiclens_analyzers")
@_cdecl("forensiclens_analyzers")
func forensiclensAnalyzers() -> UnsafeMutableRawPointer? {
    resultBuffer(WebAnalysisAPI.json(WebAnalysisAPI.analyzers()))
}

/// Analyzes `imageLength` bytes at `image`. A non-empty analyzer ID at
/// `analyzerID` runs that analyzer alone; an empty one runs them all.
@_expose(wasm, "forensiclens_analyze")
@_cdecl("forensiclens_analyze")
func forensiclensAnalyze(_ image: UnsafeRawPointer?, _ imageLength: Int32, _ analyzerID: UnsafeRawPointer?, _ analyzerIDLength: Int32) -> UnsafeMutableRawPointer? {
    let id = String(decoding: bytes(analyzerID, analyzerIDLength), as: UTF8.self)
    let response = WebAnalysisAPI.analyze(bytes(image, imageLength), only: id.isEmpty ? nil : id)
    return resultBuffer(WebAnalysisAPI.json(response))
}

/// Combines a JSON array of findings into one scored report.
@_expose(wasm, "forensiclens_combine")
@_cdecl("forensiclens_combine")
func forensiclensCombine(_ findings: UnsafeRawPointer?, _ findingsLength: Int32) -> UnsafeMutableRawPointer? {
    resultBuffer(WebAnalysisAPI.json(WebAnalysisAPI.combine(bytes(findings, findingsLength))))
}

private func bytes(_ pointer: UnsafeRawPointer?, _ length: Int32) -> [UInt8] {
    guard let pointer, length > 0 else { return [] }
    return Array(UnsafeRawBufferPointer(start: pointer, count: Int(length)))
}

private func resultBuffer(_ payload: [UInt8]) -> UnsafeMutableRawPointer? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4 + payload.count, alignment: 16)
    buffer.storeBytes(of: UInt32(payload.count).littleEndian, as: UInt32.self)
    payload.withUnsafeBytes { source in
        if let base = source.baseAddress {
            buffer.advanced(by: 4).copyMemory(from: base, byteCount: payload.count)
        }
    }
    return buffer
}
#endif
