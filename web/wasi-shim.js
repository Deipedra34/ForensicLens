// A minimal WASI (preview 1) host for running ForensicLens in a browser.
//
// The Swift runtime and Foundation are built against WASI, so the module
// imports a set of `wasi_snapshot_preview1` functions: clocks, random
// numbers, console output, and file system calls. Browsers don't provide
// WASI. Rather than pull in a polyfill library, this implements the few
// calls the analysis actually needs and answers everything else with
// ENOSYS ("not supported"). There is no file system, network, or
// environment behind it at all: the module can't read or send anything
// except what the page passes in through its exported functions.
//
// Works unchanged in browsers, web workers, and Node.js (for the smoke test).

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOSYS = 52;

/** Thrown by `proc_exit`, so a module that tries to exit unwinds cleanly. */
export class WasiExit extends Error {
  constructor(code) {
    super(`WebAssembly module exited with code ${code}`);
    this.code = code;
  }
}

/**
 * Builds the `wasi_snapshot_preview1` import object for `module`.
 * `getMemory` returns the instance's memory once it exists, since the
 * imports have to be created before the instance is.
 */
export function createWasiImports(module, getMemory, { log = console.log, logError = console.error } = {}) {
  const view = () => new DataView(getMemory().buffer);
  const bytes = () => new Uint8Array(getMemory().buffer);
  const decoder = new TextDecoder();
  const pending = { 1: "", 2: "" };

  const flushLines = (fd) => {
    const lines = pending[fd].split("\n");
    pending[fd] = lines.pop();
    for (const line of lines) (fd === 1 ? log : logError)(line);
  };

  const implemented = {
    args_sizes_get(argcPtr, argvBufSizePtr) {
      view().setUint32(argcPtr, 0, true);
      view().setUint32(argvBufSizePtr, 0, true);
      return ERRNO_SUCCESS;
    },
    args_get() {
      return ERRNO_SUCCESS;
    },
    environ_sizes_get(countPtr, bufSizePtr) {
      view().setUint32(countPtr, 0, true);
      view().setUint32(bufSizePtr, 0, true);
      return ERRNO_SUCCESS;
    },
    environ_get() {
      return ERRNO_SUCCESS;
    },
    clock_res_get(_clockId, resolutionPtr) {
      view().setBigUint64(resolutionPtr, 1000n, true);
      return ERRNO_SUCCESS;
    },
    clock_time_get(clockId, _precision, timePtr) {
      // 0 = realtime, everything else (monotonic, CPU time) = monotonic.
      const milliseconds = clockId === 0 ? Date.now() : performance.now();
      view().setBigUint64(timePtr, BigInt(Math.round(milliseconds * 1e6)), true);
      return ERRNO_SUCCESS;
    },
    random_get(bufferPtr, length) {
      // getRandomValues fills at most 65536 bytes per call.
      for (let offset = 0; offset < length; offset += 65536) {
        crypto.getRandomValues(bytes().subarray(bufferPtr + offset, bufferPtr + Math.min(length, offset + 65536)));
      }
      return ERRNO_SUCCESS;
    },
    fd_write(fd, iovsPtr, iovsLength, writtenPtr) {
      if (fd !== 1 && fd !== 2) return ERRNO_BADF;
      let written = 0;
      for (let i = 0; i < iovsLength; i++) {
        const base = view().getUint32(iovsPtr + i * 8, true);
        const length = view().getUint32(iovsPtr + i * 8 + 4, true);
        pending[fd] += decoder.decode(bytes().slice(base, base + length));
        written += length;
      }
      flushLines(fd);
      view().setUint32(writtenPtr, written, true);
      return ERRNO_SUCCESS;
    },
    fd_fdstat_get(fd, statPtr) {
      if (fd > 2) return ERRNO_BADF;
      // filetype = character device, no flags, no rights restrictions.
      new Uint8Array(getMemory().buffer, statPtr, 24).fill(0);
      view().setUint8(statPtr, 2);
      return ERRNO_SUCCESS;
    },
    fd_close(fd) {
      return fd <= 2 ? ERRNO_SUCCESS : ERRNO_BADF;
    },
    // No preopened directories: the module sees no file system at all.
    fd_prestat_get() {
      return ERRNO_BADF;
    },
    fd_prestat_dir_name() {
      return ERRNO_BADF;
    },
    sched_yield() {
      return ERRNO_SUCCESS;
    },
    proc_exit(code) {
      throw new WasiExit(code);
    },
  };

  const imports = {};
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.module !== "wasi_snapshot_preview1" || entry.kind !== "function") continue;
    imports[entry.name] = implemented[entry.name] ?? (() => ERRNO_NOSYS);
  }
  return { wasi_snapshot_preview1: imports };
}
