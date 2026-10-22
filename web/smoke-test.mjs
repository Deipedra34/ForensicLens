// Smoke test for the WebAssembly build: loads web/forensiclens.wasm in
// Node.js through the same wrapper the page's worker uses
// (forensiclens.js and wasi-shim.js), analyzes known synthetic images, and
// checks the results match what the native build produces for them. Then
// it times each analyzer on larger synthetic images.
//
//   scripts/wasm/build.sh && node web/smoke-test.mjs
//
// Needs Node.js 20 or newer. Exits non-zero if any check fails.

import { readFile } from "node:fs/promises";
import { ForensicLens } from "./forensiclens.js";

const here = new URL(".", import.meta.url);
const root = new URL("..", here);
const lens = await ForensicLens.load(await readFile(new URL("forensiclens.wasm", here)), { log: () => {}, logError: () => {} });

let failures = 0;
const check = (condition, label, detail = "") => {
  console.log(`${condition ? "PASS" : "FAIL"} ${label}${detail ? ` -- ${detail}` : ""}`);
  if (!condition) failures++;
};
const rejects = async (promise, pattern, label) => {
  try {
    await promise;
    check(false, label, "expected an error, got a result");
  } catch (error) {
    check(pattern.test(error.message), label, error.message);
  }
};
const finding = (report, id) => report.findings.find((f) => f.analyzerID === id);
const regionsOf = (f) => (f?.indicators ?? []).flatMap((indicator) => indicator.regions ?? []);
const hasRegion = (f, x, y, size) => regionsOf(f).some((r) => r.x === x && r.y === y && r.width === size && r.height === size);

// MARK: - Synthetic images (PPM/PGM)

function pnm(width, height, channels, pixels) {
  const header = new TextEncoder().encode(`${channels === 3 ? "P6" : "P5"}\n${width} ${height}\n255\n`);
  const bytes = new Uint8Array(header.length + pixels.length);
  bytes.set(header);
  bytes.set(pixels, header.length);
  return bytes;
}

// Deterministic Gaussian noise (mulberry32 + Box-Muller).
function random(seed) {
  let state = seed >>> 0;
  const uniform = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { uniform, gaussian: () => Math.sqrt(-2 * Math.log(uniform() + 1e-12)) * Math.cos(2 * Math.PI * uniform()) };
}

const clamp = (value) => Math.max(0, Math.min(255, Math.round(value)));
const scene = (x, y) => 110 + 45 * Math.sin(x / 9) * Math.cos(y / 13) + 25 * Math.sin((x + 2 * y) / 5.5);

/** A Bayer (RGGB) capture, bilinearly demosaiced, like CFAFixtures.swift. */
function demosaicedCapture(size, seed) {
  const rng = random(seed);
  const channelAt = (x, y) => ((x & 1) === 0 && (y & 1) === 0 ? 0 : (x & 1) === 1 && (y & 1) === 1 ? 2 : 1);
  const tint = [(v, x, y) => v * 1.05 + 10 * Math.sin(y / 7), (v) => v, (v, x) => v * 0.9 + 12 * Math.cos(x / 6)];
  const mosaic = new Float64Array(size * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) mosaic[y * size + x] = tint[channelAt(x, y)](scene(x, y), x, y) + 2 * rng.gaussian();
  }
  const reflect = (v) => (v < 0 ? -v : v >= size ? 2 * size - 2 - v : v);
  const pixels = new Uint8Array(size * size * 3);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      for (let c = 0; c < 3; c++) {
        let value;
        if (channelAt(x, y) === c) {
          value = mosaic[y * size + x];
        } else {
          const near = (offsets) => offsets.map(([dx, dy]) => [reflect(x + dx), reflect(y + dy)]).filter(([nx, ny]) => channelAt(nx, ny) === c);
          let neighbors = near([[-1, 0], [1, 0], [0, -1], [0, 1]]);
          if (neighbors.length === 0) neighbors = near([[-1, -1], [1, -1], [-1, 1], [1, 1]]);
          value = neighbors.reduce((sum, [nx, ny]) => sum + mosaic[ny * size + nx], 0) / neighbors.length;
        }
        pixels[(y * size + x) * 3 + c] = clamp(value);
      }
    }
  }
  return pixels;
}

/** A grayscale capture through a sensor with a 2% PRNU pattern, like PRNUFixtures.swift. */
function sensorCapture(size, seed, noiseFree) {
  const sensor = random(11);
  const noise = random(seed);
  const pixels = new Uint8Array(size * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const k = 0.02 * sensor.gaussian();
      const value = 110 + 50 * Math.sin(x / 23) + 30 * Math.cos(y / 17 + x / 41);
      pixels[y * size + x] = clamp(noiseFree(x, y) ? value : value * (1 + k) + 2 * noise.gaussian());
    }
  }
  return pixels;
}

const inSplice = (x, y) => x >= 128 && x < 192 && y >= 64 && y < 128;

// MARK: - Checks

const analyzers = await lens.analyzers();
check(
  JSON.stringify(analyzers.map((a) => a.id)) === JSON.stringify(["ela", "metadata", "clone", "doublecompression", "prnu", "cfa"]),
  "lists every analyzer in run order",
  analyzers.map((a) => a.id).join(", ")
);

const copyMove = new Uint8Array(await readFile(new URL("samples/copy-move.ppm", here)));
const full = await lens.analyze(copyMove);
const clone = finding(full.report, "clone");
check(full.image?.pixelsDecoded === true && full.image.width > 0, "decodes the sample PPM", `${full.image?.width}x${full.image?.height}`);
check(full.report.findings.length === 6, "runs all six analyzers", `${full.report.findings.length} findings`);
check(clone?.score > 0 && regionsOf(clone).length >= 2, "detects the sample's copy-move forgery", `clone score ${clone?.score?.toFixed(1)}, ${regionsOf(clone).length} regions`);
check(full.report.overallScore >= clone.score, "overall score reflects it", `overall ${full.report.overallScore.toFixed(1)}, ${full.report.verdict}`);

// The page runs one analyzer per call and combines; that must equal one full run.
const perAnalyzer = [];
for (const analyzer of analyzers) perAnalyzer.push(...(await lens.analyze(copyMove, analyzer.id)).report.findings);
const combined = (await lens.combine(perAnalyzer)).report;
check(Math.abs(combined.overallScore - full.report.overallScore) < 1e-9, "per-analyzer runs combine to the full-run score", `${combined.overallScore.toFixed(3)} vs ${full.report.overallScore.toFixed(3)}`);

const uniform = new Uint8Array(await readFile(new URL(".github/action-test-fixtures/clean/uniform.ppm", root)));
const clean = await lens.analyze(uniform);
check(clean.report.overallScore === 0, "a uniform image scores 0", clean.report.verdict);

const cfaImage = demosaicedCapture(256, 5);
const splice = random(99);
for (let y = 64; y < 128; y++) for (let x = 128; x < 192; x++) for (let c = 0; c < 3; c++) cfaImage[(y * 256 + x) * 3 + c] = Math.floor(splice.uniform() * 256);
const cfa = finding((await lens.analyze(pnm(256, 256, 3, cfaImage), "cfa")).report, "cfa");
check(hasRegion(cfa, 128, 64, 64) && regionsOf(cfa).every((r) => r.x === 128 && r.y === 64), "CFA flags exactly a spliced block without a Bayer pattern", cfa?.summary);

const prnuImage = sensorCapture(256, 101, inSplice);
const prnu = finding((await lens.analyze(pnm(256, 256, 1, prnuImage), "prnu")).report, "prnu");
check(hasRegion(prnu, 128, 64, 64) && regionsOf(prnu).every((r) => r.x === 128 && r.y === 64), "PRNU flags exactly a spliced block with no sensor noise", prnu?.summary);

// Errors must come back as readable JavaScript errors, never a crashed module.
await rejects(lens.analyze(new Uint8Array([1, 2, 3, 4])), /Unrecognized image format/, "rejects unrecognized bytes with a clear error");
await rejects(lens.analyze(new TextEncoder().encode("P6\n100 100\n255\nabc")), /Could not decode the image/, "rejects a truncated PPM with a clear error");
await rejects(lens.analyze(new Uint8Array()), /No image data/, "rejects empty input");
await rejects(lens.analyze(copyMove, "nonexistent"), /Unknown analyzer/, "rejects an unknown analyzer");
await rejects(lens.combine("not findings"), /Could not read the findings/, "rejects malformed findings");
const jpeg = await lens.analyze(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
check(jpeg.image.pixelsDecoded === false && finding(jpeg.report, "ela").summary.startsWith("Could not run"), "a JPEG gets metadata analysis only", finding(jpeg.report, "ela").summary);
const afterErrors = await lens.analyze(uniform);
check(afterErrors.report.overallScore === 0, "the module keeps working after errors");

// MARK: - Timing

console.log("\nTiming (synthetic demosaiced RGB captures, this runtime):");
for (const size of [512, 1024]) {
  const bytes = pnm(size, size, 3, demosaicedCapture(size, 7));
  const times = [];
  let total = 0;
  for (const analyzer of analyzers) {
    const start = performance.now();
    await lens.analyze(bytes, analyzer.id);
    const elapsed = performance.now() - start;
    total += elapsed;
    times.push(`${analyzer.id} ${(elapsed / 1000).toFixed(2)}s`);
  }
  console.log(`TIMING ${size}x${size}: total ${(total / 1000).toFixed(2)}s (${times.join(", ")})`);
}

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
