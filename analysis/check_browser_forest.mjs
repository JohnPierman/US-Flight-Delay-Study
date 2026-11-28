// Compare the published evaluator to R prediction fixtures produced by the exporter.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { decodeForest, encodeScenario, forestProbability, startScenario } from "../docs/forest-engine.mjs";

const [site, fixtures] = process.argv.slice(2);
if (!site || !fixtures) throw new Error("Usage: node analysis/check_browser_forest.mjs SITE_DIR QA_DIR");
const json = (path) => JSON.parse(readFileSync(path, "utf8"));
const schema = json(join(site, "forest-controls.json"));

for (const [name, meta] of Object.entries(schema)) {
  const binary = gunzipSync(readFileSync(join(site, meta.file)));
  const model = decodeForest(meta, Uint8Array.from(binary).buffer);
  const { inputs, expected } = json(join(fixtures, name + ".json"));
  inputs.forEach((input, i) => checkMass(input.map(Number), expected[i]));
  const initial = startScenario(meta.controls);
  const encoded = encodeScenario(meta, initial);
  checkMass(encoded, expected[0]);

  for (const control of meta.controls) {
    const next = startScenario(meta.controls);
    const value = next[control.id];
    if (value.missing) value.missing = false;
    if (control.type === "range") value.value = (value.value + 1) % control.values.length;
    else value.value = control.choices.find(choice => choice.value !== value.value).value;
    const changed = encodeScenario(meta, next);
    const allowed = new Set(control.indexes ?? [control.index, control.missing?.index]);
    assert(changed.some((value, i) => value !== encoded[i]), name + " unchanged " + control.id);
    changed.forEach((value, i) => {
      if (!allowed.has(i)) assert.equal(value, encoded[i], name + " changed another input");
    });
  }
  console.log(name + ": " + inputs.length + " R fixtures match and all controls isolate their inputs");

  function checkMass(input, expected) {
    const mass = forestProbability(model, input);
    assert.equal(mass.length, expected.length);
    assert(Math.abs(mass.reduce((sum, p) => sum + p, 0) - 1) < 1e-12, name + " unnormalized");
    const error = Math.max(...mass.map((p, i) => Math.abs(p - expected[i])));
    assert(error < 1e-12, name + " differs from R by " + error);
  }
}
