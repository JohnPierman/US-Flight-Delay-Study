// Browser evaluator for the ordered ranger regression trees and their leaf PMFs.
export function decodeForest(metadata, buffer) {
  const { nodes, entries, roots, support } = metadata;
  const offset = {
    left: nodes * 8,
    leaf: nodes * 12,
    bins: nodes * 12 + (nodes + 1) * 4
  };
  offset.counts = offset.bins + entries * 2;
  offset.feature = offset.counts + entries * 2;
  if (buffer.byteLength !== offset.feature + nodes) throw new Error("Invalid forest model size");
  return { metadata, roots, support, offset, data: new DataView(buffer) };
}

export function startScenario(controls) {
  return Object.fromEntries(controls.map(control => [
    control.id, { value: control.initial, missing: control.missing?.initial ?? false }
  ]));
}

export function encodeScenario(metadata, scenario) {
  const features = new Float64Array(metadata.features.length);
  for (const control of metadata.controls) {
    const input = scenario[control.id];
    if (control.type === "month") {
      const pair = control.choices.find(choice => choice.value === input.value).pair;
      control.indexes.forEach((index, i) => { features[index] = pair[i]; });
    } else if (control.type === "range") {
      const missing = Boolean(control.missing && input.missing);
      const value = input.value === control.initial ? control.baseline : control.values[input.value] / control.scale;
      features[control.index] = missing ? control.missing.center : value;
      if (control.missing) features[control.missing.index] = Number(missing);
    } else {
      features[control.index] = input.value;
    }
  }
  return features;
}

export function forestProbability(forest, features) {
  const { roots, data, offset, support } = forest;
  const mass = new Float64Array(support.length);
  for (const root of roots) {
    let node = root;
    let child = data.getUint32(offset.left + node * 4, true);
    while (child !== 0) {
      const feature = data.getUint8(offset.feature + node);
      const threshold = data.getFloat64(node * 8, true);
      node = root + child + Number(features[feature] > threshold);
      child = data.getUint32(offset.left + node * 4, true);
    }
    const start = data.getUint32(offset.leaf + node * 4, true);
    const end = data.getUint32(offset.leaf + (node + 1) * 4, true);
    let count = 0;
    for (let i = start; i < end; i++) count += data.getUint16(offset.counts + i * 2, true);
    if (count === 0) throw new Error("Empty prediction leaf");
    const normalizer = 1 / (count * roots.length);
    for (let i = start; i < end; i++) {
      const index = data.getUint16(offset.bins + i * 2, true);
      mass[index] += data.getUint16(offset.counts + i * 2, true) * normalizer;
    }
  }
  return mass;
}

export function makeDensityKernel(support, grid, bandwidth) {
  const normalizer = 1 / (bandwidth * Math.sqrt(2 * Math.PI));
  const size = Math.round((grid.to - grid.from) / grid.step) + 1;
  return Array.from({ length: size }, (_, i) => {
    const x = grid.from + i * grid.step;
    return Float64Array.from(support, minute => normalizer * Math.exp(-0.5 * ((x - minute) / bandwidth) ** 2));
  });
}

export function summarizeProbability(mass, support, kernel) {
  let cumulative = 0;
  let p30 = 0;
  let q05, median, q95;
  for (let i = 0; i < mass.length; i++) {
    cumulative += mass[i];
    if (cumulative >= 0.05 - 1e-12 && q05 === undefined) q05 = support[i];
    if (cumulative >= 0.50 - 1e-12 && median === undefined) median = support[i];
    if (cumulative >= 0.95 - 1e-12 && q95 === undefined) q95 = support[i];
    if (support[i] >= 30) p30 += mass[i];
  }
  const density = kernel.map(weights => {
    let value = 0;
    for (let i = 0; i < weights.length; i++) value += weights[i] * mass[i];
    return value;
  });
  return { density, median, q05, q95, p30 };
}

export function predictCurve(forest, scenario, kernel) {
  const encoded = encodeScenario(forest.metadata, scenario);
  const mass = forestProbability(forest, encoded);
  return summarizeProbability(mass, forest.support, kernel);
}

export async function downloadForest(metadata) {
  const response = await fetch("./" + metadata.file);
  if (!response.ok) throw new Error("Forest model HTTP " + response.status);
  let buffer = await response.arrayBuffer();
  const magic = new Uint8Array(buffer, 0, 2);
  if (magic[0] === 0x1f && magic[1] === 0x8b) {
    const stream = new Blob([buffer]).stream().pipeThrough(new DecompressionStream("gzip"));
    buffer = await new Response(stream).arrayBuffer();
  }
  return decodeForest(metadata, buffer);
}
