// JavaScript wrapper around the ForensicLens WebAssembly module.
//
// `ForensicLens.load(source)` compiles `forensiclens.wasm` once. After that,
// every call creates a *fresh* instance of the compiled module. That's a few
// milliseconds, and it means each analysis starts with clean memory. It also
// means that if Swift ever traps on a bug (an "unreachable" error in
// JavaScript), the failure is confined to that one call and the page keeps
// working. All data stays in this process: bytes go into the instance's
// memory, JSON comes back out, and nothing is sent anywhere.
//
// Shared by the page's web worker and the Node.js smoke test.

import { createWasiImports, WasiExit } from "./wasi-shim.js";

/**
 * The engine itself failed (a trap or an attempted exit), as opposed to
 * the input being unusable. Only the one call is lost; the next call gets
 * a fresh instance.
 */
export class EngineFailure extends Error {}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class ForensicLens {
  /** @param {WebAssembly.Module} module */
  constructor(module, options = {}) {
    this.module = module;
    this.options = options;
  }

  /**
   * Compiles the module from a URL (fetched, streamed where the server
   * sends `application/wasm`), a `Response`, or raw bytes.
   */
  static async load(source, options = {}) {
    let module;
    if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
      module = await WebAssembly.compile(source);
    } else {
      const response = source instanceof Response ? source : await fetch(source);
      if (!response.ok) throw new Error(`Could not load ${response.url}: HTTP ${response.status}`);
      try {
        module = await WebAssembly.compileStreaming(response.clone());
      } catch {
        // Servers that don't label .wasm files as application/wasm.
        module = await WebAssembly.compile(await response.arrayBuffer());
      }
    }
    return new ForensicLens(module, options);
  }

  /** Every analyzer, in run order: `[{id, name}]`. */
  async analyzers() {
    return this.#call((exports) => exports.forensiclens_analyzers());
  }

  /**
   * Analyzes `imageBytes` (a Uint8Array) with one analyzer (`analyzerID`)
   * or all of them (empty string). Resolves to `{report, image}`. Rejects
   * with a readable Error for undecodable input or a module failure.
   */
  async analyze(imageBytes, analyzerID = "") {
    return this.#call((exports, pass) => {
      const image = pass(imageBytes);
      const id = pass(encoder.encode(analyzerID));
      return exports.forensiclens_analyze(image.pointer, image.length, id.pointer, id.length);
    });
  }

  /** Combines findings from separate `analyze` calls into one report. */
  async combine(findings) {
    return this.#call((exports, pass) => {
      const json = pass(encoder.encode(JSON.stringify(findings)));
      return exports.forensiclens_combine(json.pointer, json.length);
    });
  }

  async #call(body) {
    let memory;
    const imports = createWasiImports(this.module, () => memory, this.options);
    const instance = await WebAssembly.instantiate(this.module, imports);
    const exports = instance.exports;
    memory = exports.memory;

    const allocations = [];
    // Copies bytes into the module's memory and remembers to free them.
    const pass = (data) => {
      const pointer = exports.forensiclens_alloc(data.length);
      if (!pointer) throw new Error("The WebAssembly module ran out of memory.");
      new Uint8Array(memory.buffer, pointer, data.length).set(data);
      allocations.push(pointer);
      return { pointer, length: data.length };
    };

    try {
      exports._initialize?.();
      const result = body(exports, pass);
      if (!result) throw new Error("The WebAssembly module ran out of memory.");
      // Re-read the buffer after the call: memory may have grown.
      const length = new DataView(memory.buffer).getUint32(result, true);
      const json = decoder.decode(new Uint8Array(memory.buffer, result + 4, length).slice());
      exports.forensiclens_free(result);
      const value = JSON.parse(json);
      if (value && typeof value === "object" && !Array.isArray(value) && value.error) {
        throw new Error(value.error);
      }
      return value;
    } catch (error) {
      if (error instanceof WasiExit || error instanceof WebAssembly.RuntimeError) {
        throw new EngineFailure(`The analysis engine stopped unexpectedly (${error.message}).`);
      }
      throw error;
    } finally {
      for (const pointer of allocations) {
        try {
          exports.forensiclens_free(pointer);
        } catch {
          // The instance is discarded anyway.
        }
      }
    }
  }
}
