// Runs the analysis off the page's main thread, so the page stays
// responsive (and its progress bar keeps moving) while the heavier
// analyzers work. Each analyzer runs as its own call, so progress can be
// reported analyzer by analyzer and an engine failure in one doesn't lose
// the others. The findings are then combined into one scored report, the
// same way a single full run combines them.
//
// The only network request this worker makes is fetching forensiclens.wasm
// itself. Image bytes arrive by postMessage from the page and never leave
// this process.

import { ForensicLens, EngineFailure } from "./forensiclens.js";

let enginePromise = null;

function engine() {
  enginePromise ??= ForensicLens.load(new URL("forensiclens.wasm", import.meta.url));
  // A failed load (missing file, unsupported browser) shouldn't stick.
  enginePromise.catch(() => {
    enginePromise = null;
  });
  return enginePromise;
}

self.onmessage = async (event) => {
  const { type, id, bytes } = event.data ?? {};
  if (type !== "analyze") return;
  const post = (message) => self.postMessage({ id, ...message });

  try {
    post({ type: "progress", step: "Loading the analysis engine..." });
    const lens = await engine();
    const analyzers = await lens.analyzers();
    const image = new Uint8Array(bytes);

    const findings = [];
    const timings = {};
    let imageInfo = null;
    for (const [index, analyzer] of analyzers.entries()) {
      post({ type: "progress", step: analyzer.name, index, total: analyzers.length });
      const start = performance.now();
      try {
        const result = await lens.analyze(image, analyzer.id);
        imageInfo ??= result.image;
        findings.push(...result.report.findings);
      } catch (error) {
        // Undecodable input fails the same way for every analyzer, so it
        // ends the whole run. An engine failure only costs this analyzer.
        if (!(error instanceof EngineFailure)) throw error;
        findings.push({ analyzerID: analyzer.id, score: 0, summary: `Could not run ${analyzer.name}: ${error.message}`, indicators: [] });
      }
      timings[analyzer.id] = performance.now() - start;
    }

    post({ type: "progress", step: "Combining results...", index: analyzers.length, total: analyzers.length });
    const { report } = await lens.combine(findings);
    post({ type: "done", report, image: imageInfo, analyzers, timings });
  } catch (error) {
    post({ type: "error", message: error?.message ?? String(error) });
  }
};
