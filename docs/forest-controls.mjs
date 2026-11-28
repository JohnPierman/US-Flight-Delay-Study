import { downloadForest, makeDensityKernel, predictCurve, startScenario } from "./forest-engine.mjs";

const modelNames = {
  heat: "Departure heat forest",
  rotation: "Retrospective inbound forest",
  cutoff: "One-hour cutoff forest"
};

export function createForestControls({ container, onChange, grid, bandwidth, clock }) {
  const models = new Map();
  let metadataRequest;
  let key = "heat";
  let rendered;

  function select(modelKey) {
    key = modelKey;
    let entry = models.get(key);
    if (!entry || entry.error) {
      const requestedKey = key;
      entry = { loading: true };
      models.set(key, entry);
      load(requestedKey, entry);
    }
    refresh();
    onChange();
  }

  async function load(requestedKey, entry) {
    try {
      if (!metadataRequest) {
        metadataRequest = fetch("./forest-controls.json").then(response => {
          if (!response.ok) throw new Error("Forest settings HTTP " + response.status);
          return response.json();
        }).catch(error => {
          metadataRequest = null;
          throw error;
        });
      }
      const schema = (await metadataRequest)[requestedKey];
      entry.forest = await downloadForest(schema);
      entry.current = startScenario(schema.controls);
      entry.reference = startScenario(schema.controls);
      entry.kernel = makeDensityKernel(schema.support, grid, bandwidth);
      entry.referenceCurve = predictCurve(entry.forest, entry.reference, entry.kernel);
      entry.loading = false;
    } catch (error) {
      console.error(error);
      entry.loading = false;
      entry.error = true;
    }
    if (requestedKey === key) {
      refresh();
      onChange();
    }
  }

  function refresh() {
    const entry = models.get(key);
    if (rendered === entry && entry.refreshers) return;
    rendered = entry;
    container.replaceChildren();
    if (entry.loading) {
      container.append(node("p", "field-note", "Loading this fitted forest…"));
      return;
    }
    if (entry.error) {
      container.append(node("p", "field-note", "This forest could not be loaded."));
      const retry = node("button", "pin", "Try again");
      retry.type = "button";
      retry.addEventListener("click", () => select(key));
      container.append(retry);
      return;
    }
    const groups = new Map();
    entry.refreshers = [];
    for (const control of entry.forest.metadata.controls) {
      if (!groups.has(control.group)) {
        const group = node("details", "advanced-group");
        group.open = control.group === "Flight schedule" || control.group === "Departure weather";
        group.append(node("summary", "", control.group));
        groups.set(control.group, group);
        container.append(group);
      }
      groups.get(control.group).append(buildControl(entry, control));
    }
    updateInputs(entry);
  }

  function buildControl(entry, control) {
    const wrapper = node("div", "advanced-control");
    const id = "advanced-" + control.id;
    const label = node("label", "select-label", control.label);
    label.htmlFor = id;

    if (control.type !== "range") {
      const input = node("select");
      input.id = id;
      for (const choice of control.choices) {
        const option = node("option", "", choice.label);
        option.value = choice.value;
        input.append(option);
      }
      input.addEventListener("change", () => {
        entry.current[control.id].value = Number(input.value);
        onChange();
      });
      entry.refreshers.push(() => { input.value = entry.current[control.id].value; });
      wrapper.append(label, input);
      return wrapper;
    }

    const header = node("div", "slider-heading");
    const output = node("output");
    output.setAttribute("for", id);
    header.append(label, output);
    const input = node("input");
    input.id = id;
    input.type = "range";
    input.min = 0;
    input.max = control.values.length - 1;
    input.step = 1;
    input.addEventListener("input", () => {
      entry.current[control.id].value = Number(input.value);
      updateInput();
      onChange();
    });
    const ends = node("div", "range-ends");
    ends.setAttribute("aria-hidden", "true");
    ends.append(node("span", "", format(control, control.values[0])),
      node("span", "", format(control, control.values.at(-1))));
    wrapper.append(header, input, ends);

    let missing;
    if (control.missing) {
      const row = node("label", "missing-switch");
      missing = node("input");
      missing.type = "checkbox";
      missing.setAttribute("aria-label", control.label + " missing");
      missing.addEventListener("change", () => {
        entry.current[control.id].missing = missing.checked;
        updateInput();
        onChange();
      });
      row.append(missing, document.createTextNode("Observation missing"));
      wrapper.append(row);
    }
    entry.refreshers.push(updateInput);
    return wrapper;

    function updateInput() {
      const value = entry.current[control.id];
      input.value = value.value;
      input.disabled = value.missing;
      const text = value.missing ? "Imputed " + format(control, control.missing.center * control.scale)
        : format(control, control.values[value.value]);
      output.textContent = text;
      input.setAttribute("aria-valuetext", text);
      input.style.setProperty("--fraction", (value.value * 100 / (+input.max || 1)) + "%");
      if (missing) missing.checked = value.missing;
    }
  }

  function format(control, value) {
    if (control.unit === "clock") return clock(Math.round(value));
    const unit = { deg: "°", degC: " °C", min: " min", mi: " mi", flights: "", kt: " kt", km: " km" }[control.unit];
    return new Intl.NumberFormat("en-CA", { maximumFractionDigits: 2 }).format(value) + unit;
  }

  function updateInputs(entry) {
    entry.refreshers.forEach(refresh => refresh());
  }

  function cutoffViolation(entry) {
    if (key !== "cutoff") return "";
    const inputs = entry.forest.metadata.controls;
    const turn = inputs.find(control => control.id === "turn_hours");
    const prior = inputs.find(control => control.id === "prior_delay_30");
    const maximum = turn.values[entry.current.turn_hours.value] - 60;
    if (prior.values[entry.current.prior_delay_30.value] <= maximum + 1e-10) return "";
    const formatted = new Intl.NumberFormat("en-CA", { maximumFractionDigits: 2 }).format(maximum);
    return "At this turnaround, the previous arrival delay must be " + formatted +
      " min or less for the aircraft to have landed by the one-hour cutoff.";
  }

  function snapshot() {
    const entry = models.get(key);
    if (!entry || entry.loading || entry.error) {
      return { title: modelNames[key], pending: true,
        message: entry?.error ? "Model unavailable" : "Loading model…" };
    }
    const invalid = cutoffViolation(entry);
    const reference = entry.referenceCurve;
    const current = invalid ? null : predictCurve(entry.forest, entry.current, entry.kernel);
    const changed = entry.forest.metadata.controls.filter(control => {
      const a = entry.current[control.id];
      const b = entry.reference[control.id];
      return a.missing !== b.missing || (!a.missing && a.value !== b.value);
    }).length;
    const message = changed === 0 ? "Current and reference use the same inputs"
      : changed + (changed === 1 ? " input differs" : " inputs differ") + " from the reference";
    return { title: modelNames[key], current, reference, message, invalid };
  }

  function pin() {
    const entry = models.get(key);
    if (!entry?.forest || cutoffViolation(entry)) return;
    entry.reference = structuredClone(entry.current);
    entry.referenceCurve = predictCurve(entry.forest, entry.reference, entry.kernel);
    onChange();
  }

  function reset() {
    const entry = models.get(key);
    if (!entry?.forest) return;
    entry.current = startScenario(entry.forest.metadata.controls);
    updateInputs(entry);
    pin();
  }

  return { select, snapshot, pin, reset };
}

function node(tag, className = "", text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}
