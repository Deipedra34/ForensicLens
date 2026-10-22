// Decodes binary PPM (P6) and PGM (P5) images to RGBA for the preview
// canvas, since browsers can't display them. Returns `null` for anything
// else (BMP, JPEG, or an unsupported PNM variant), so the caller can fall
// back to the browser's own decoders. Only 8-bit (maxval <= 255) images
// are supported, which is also all the analysis engine decodes.

export function decodePortableAnymap(bytes) {
  if (bytes.length < 3 || bytes[0] !== 0x50 || (bytes[1] !== 0x35 && bytes[1] !== 0x36)) return null;
  const channels = bytes[1] === 0x36 ? 3 : 1;

  // Header: magic, width, height, maxval, separated by whitespace, with
  // optional '#' comments; then exactly one whitespace byte before pixels.
  let position = 2;
  const isSpace = (byte) => byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d || byte === 0x0b || byte === 0x0c;
  const readNumber = () => {
    while (position < bytes.length) {
      if (isSpace(bytes[position])) {
        position++;
      } else if (bytes[position] === 0x23) {
        while (position < bytes.length && bytes[position] !== 0x0a) position++;
      } else {
        break;
      }
    }
    let value = 0;
    let digits = 0;
    while (position < bytes.length && bytes[position] >= 0x30 && bytes[position] <= 0x39) {
      value = value * 10 + (bytes[position] - 0x30);
      position++;
      digits++;
    }
    return digits > 0 ? value : NaN;
  };

  const width = readNumber();
  const height = readNumber();
  const maxValue = readNumber();
  if (!(width > 0 && height > 0 && maxValue > 0 && maxValue <= 255)) return null;
  position++; // the single whitespace byte after maxval

  const pixelCount = width * height;
  if (bytes.length - position < pixelCount * channels) return null;
  const rgba = new Uint8ClampedArray(pixelCount * 4);
  const scale = 255 / maxValue;
  for (let i = 0; i < pixelCount; i++) {
    const source = position + i * channels;
    const r = bytes[source];
    const g = channels === 3 ? bytes[source + 1] : r;
    const b = channels === 3 ? bytes[source + 2] : r;
    rgba[i * 4] = r * scale;
    rgba[i * 4 + 1] = g * scale;
    rgba[i * 4 + 2] = b * scale;
    rgba[i * 4 + 3] = 255;
  }
  return { width, height, rgba };
}
