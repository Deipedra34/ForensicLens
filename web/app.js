// The demo page: reads an image file locally, hands its bytes to the
// analysis worker, and renders the report, with overlay boxes for every
// region an analyzer flagged.
//
// All rendering uses textContent and DOM APIs rather than HTML strings,
// since findings echo text taken from the image's own metadata.

import { decodePortableAnymap } from "./pnm.js";

const layerColors = {
  ela: "#f76707",
  clone: "#1c7ed6",
  doublecompression: "#ae3ec9",
  prnu: "#2f9e44",
  cfa: "#e64980",
};
const fallbackColor = "#868e96";

const $ = (id) => document.getElementById(id);
const worker = new Worker(new URL("worker.js", import.meta.url), { type: "module" });
let currentRun = 0;
let currentFile = null;
let currentPreview = null;

// MARK: - Input

$("file-input").addEventListener("change", (event) => {
  const [file] = event.target.files;
  if (file) analyzeFile(file);
  event.target.value = "";
});

const dropZone = $("drop-zone");
for (const name of ["dragenter", "dragover"]) {
  dropZone.addEventListener(name, (event) => {
    event.preventDefault();
    dropZone.classList.add("dragging");
  });
}
for (const name of ["dragleave", "drop"]) {
  dropZone.addEventListener(name, () => dropZone.classList.remove("dragging"));
}
dropZone.addEventListener("drop", (event) => {
  event.preventDefault();
  const [file] = event.dataTransfer.files;
  if (file) analyzeFile(file);
});
dropZone.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") $("file-input").click();
});

$("sample-button").addEventListener("click", async () => {
  try {
    const response = await fetch("samples/copy-move.ppm");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    analyzeFile(new File([await response.blob()], "copy-move.ppm"));
  } catch (error) {
    showError(`Could not load the sample image: ${error.message}`);
  }
});

async function analyzeFile(file) {
  const run = ++currentRun;
  currentFile = file;
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (run !== currentRun) return;

  $("error-card").hidden = true;
  $("results").hidden = true;
  $("progress-card").hidden = false;
  setProgress("Reading the image...", 0);

  // A copy goes to the worker; the original stays here for the preview.
  const copy = bytes.slice();
  worker.postMessage({ type: "analyze", id: run, bytes: copy.buffer }, [copy.buffer]);
  currentPreview = renderPreview(bytes);
}

// MARK: - Worker messages

worker.addEventListener("message", async (event) => {
  const message = event.data;
  if (message.id !== currentRun) return;

  if (message.type === "progress") {
    const fraction = message.total ? message.index / message.total : 0;
    const label = message.total ? `Running ${message.step} (${message.index + 1} of ${message.total})...` : message.step;
    setProgress(message.index === message.total ? message.step : label, fraction);
  } else if (message.type === "error") {
    $("progress-card").hidden = true;
    showError(message.message);
  } else if (message.type === "done") {
    $("progress-card").hidden = true;
    const preview = await currentPreview;
    renderResults(message, preview);
  }
});

worker.addEventListener("error", (event) => {
  $("progress-card").hidden = true;
  showError(`The analysis worker failed to start (${event.message || "this browser may not support module workers"}).`);
});

function setProgress(label, fraction) {
  $("progress-label").textContent = label;
  $("progress-bar").value = fraction;
}

function showError(text) {
  $("error-message").textContent = text;
  $("error-card").hidden = false;
}

// MARK: - Preview

/**
 * Draws the image onto the canvas. Browsers display BMP and JPEG
 * themselves; PPM/PGM are decoded here. Resolves to `{width, height}`, or
 * `null` if the image can't be previewed (the report still renders).
 */
async function renderPreview(bytes) {
  const canvas = $("image-canvas");
  const context = canvas.getContext("2d");
  try {
    const pnm = decodePortableAnymap(bytes);
    if (pnm) {
      canvas.width = pnm.width;
      canvas.height = pnm.height;
      context.putImageData(new ImageData(pnm.rgba, pnm.width, pnm.height), 0, 0);
      return { width: pnm.width, height: pnm.height };
    }
    const bitmap = await createImageBitmap(new Blob([bytes]));
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    context.drawImage(bitmap, 0, 0);
    return { width: bitmap.width, height: bitmap.height };
  } catch {
    canvas.width = 0;
    canvas.height = 0;
    return null;
  }
}

// MARK: - Results

function severity(score) {
  if (score < 20) return "low";
  if (score < 45) return "minor";
  if (score < 70) return "medium";
  return "high";
}

function renderResults({ report, image, analyzers, timings }, preview) {
  const names = Object.fromEntries(analyzers.map((analyzer) => [analyzer.id, analyzer.name]));
  const score = Math.round(report.overallScore);

  $("file-name").textContent = currentFile?.name ?? "Image";
  const details = [];
  if (image?.format) details.push(image.format.toUpperCase());
  if (image?.width) details.push(`${image.width}×${image.height} px`);
  const totalSeconds = Object.values(timings).reduce((sum, value) => sum + value, 0) / 1000;
  details.push(`analyzed in ${totalSeconds.toFixed(1)} s`);
  $("image-details").textContent = details.join(" · ");
  $("verdict").textContent = `Verdict: ${report.verdict}`;
  $("score-value").textContent = String(score);
  $("overall-score").className = `score ${severity(score)}`;

  renderOverlay(report, names, image, preview);
  renderFindings(report, names, timings);
  $("results").hidden = false;
}

function renderOverlay(report, names, image, preview) {
  const width = image?.width ?? preview?.width;
  const height = image?.height ?? preview?.height;
  const svg = $("overlay");
  const toggles = $("layer-toggles");
  svg.replaceChildren();
  toggles.replaceChildren();

  const note = $("preview-note");
  note.hidden = true;
  if (!preview) {
    note.textContent = "This browser can't display this image format, so flagged regions are listed below without a preview.";
    note.hidden = false;
  }
  $("stage").hidden = !preview;
  if (!width || !height) return;
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

  for (const finding of report.findings) {
    const seen = new Set();
    const regions = [];
    for (const indicator of finding.indicators) {
      for (const region of indicator.regions ?? []) {
        const key = `${region.x},${region.y},${region.width},${region.height}`;
        if (!seen.has(key)) {
          seen.add(key);
          regions.push(region);
        }
      }
    }
    if (regions.length === 0) continue;

    const color = layerColors[finding.analyzerID] ?? fallbackColor;
    const layer = document.createElementNS("http://www.w3.org/2000/svg", "g");
    layer.dataset.layer = finding.analyzerID;
    layer.style.setProperty("--layer-color", color);
    for (const region of regions) {
      const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
      rect.setAttribute("class", "overlay-box");
      rect.setAttribute("x", region.x);
      rect.setAttribute("y", region.y);
      rect.setAttribute("width", region.width);
      rect.setAttribute("height", region.height);
      layer.append(rect);
    }
    svg.append(layer);

    const label = document.createElement("label");
    label.className = "toggle";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = true;
    checkbox.addEventListener("change", () => {
      layer.style.display = checkbox.checked ? "" : "none";
    });
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = color;
    label.append(checkbox, swatch, `${names[finding.analyzerID] ?? finding.analyzerID} (${regions.length} region${regions.length === 1 ? "" : "s"})`);
    toggles.append(label);
  }
}

function renderFindings(report, names, timings) {
  const container = $("findings");
  container.replaceChildren();
  for (const finding of report.findings) {
    const score = Math.round(finding.score);
    const item = document.createElement("details");
    item.className = "finding";
    item.open = finding.score > 0;

    const summary = document.createElement("summary");
    const title = document.createElement("span");
    title.className = "finding-name";
    title.textContent = names[finding.analyzerID] ?? finding.analyzerID;
    const bar = document.createElement("span");
    bar.className = "bar";
    const fill = document.createElement("span");
    fill.className = `fill ${severity(finding.score)}`;
    fill.style.width = `${Math.max(0, Math.min(100, finding.score))}%`;
    bar.append(fill);
    const value = document.createElement("span");
    value.className = "finding-score";
    value.textContent = `${score}/100`;
    summary.append(title, bar, value);

    const text = document.createElement("p");
    text.textContent = finding.summary;
    item.append(summary, text);

    if (finding.indicators.length > 0) {
      const list = document.createElement("ul");
      for (const indicator of finding.indicators) {
        const entry = document.createElement("li");
        entry.textContent = indicator.message;
        list.append(entry);
      }
      item.append(list);
    }

    const time = timings[finding.analyzerID];
    if (time !== undefined) {
      const timing = document.createElement("p");
      timing.className = "muted";
      timing.textContent = `${(time / 1000).toFixed(2)} s`;
      item.append(timing);
    }
    container.append(item);
  }
}
