import { createForestControls } from "./forest-controls.mjs";

const element = id => document.getElementById(id);
const state = { dataset: null, question: "heat", mode: "rotation", views: {}, hover: null, chart: null, advanced: null };
const palette = { current: "#08796f", reference: "#657e9d", grid: "#e9eff1", axis: "#476371" };
const signed = value => String(value).replace("-", "−");
const minutes = value => signed(value) + " min";
const percent = value => (value * 100).toFixed(1) + "%";
const clock = minute => {
  const hour = Math.floor(minute / 60);
  return (hour % 12 || 12) + ":" + String(minute % 60).padStart(2, "0") + (hour < 12 ? " AM" : " PM");
};

function initial(key) {
  const data = state.dataset[key];
  return key === "heat" ? { heat: data.initial } : { time: data.initial_time, prior: data.initial_prior };
}

function activeKey() {
  return state.question === "heat" ? "heat" : state.mode;
}

function activeView() {
  const key = activeKey();
  return { key, data: state.dataset[key], settings: state.views[key] };
}

function curveAt(key, view, location) {
  return key === "heat" ? view.curves[location.heat] : view.times[location.time].curves[location.prior];
}

function describe(key, view, location) {
  if (key === "heat") return view.values[location.heat] + " °C";
  const slot = view.times[location.time];
  return clock(slot.minute) + " departure, " + minutes(slot.values[location.prior]) + " inbound";
}

function nearest(values, target) {
  return values.reduce((closest, value, index) =>
    Math.abs(value - target) < Math.abs(values[closest] - target) ? index : closest, 0);
}

function setRange(id, values, index, formatter) {
  const input = element(id);
  input.min = 0;
  input.max = values.length - 1;
  input.step = 1;
  input.value = index;
  const text = formatter(values[index]);
  input.setAttribute("aria-valuetext", text);
  input.style.setProperty("--fraction", (index * 100 / (values.length - 1 || 1)) + "%");
  element(id + "-value").textContent = text;
  element(id + "-low").textContent = formatter(values[0]);
  element(id + "-high").textContent = formatter(values.at(-1));
}

function yScale(key) {
  const view = state.dataset[key];
  const groups = key === "heat" ? [view.curves] : view.times.map(slot => slot.curves);
  const max = Math.max(...groups.flatMap(group => group.map(curve => Math.max(...curve.density))));
  return Math.max(0.02, Math.ceil(max * 50) / 50);
}

function update() {
  const advanced = state.question === "all";
  const inbound = state.question === "inbound";
  const heat = state.question === "heat";
  element("heat-tab").setAttribute("aria-pressed", heat);
  element("inbound-tab").setAttribute("aria-pressed", inbound);
  element("all-tab").setAttribute("aria-pressed", advanced);
  element("workspace").classList.toggle("advanced", advanced);
  element("all-field").hidden = !advanced;
  element("temperature-field").hidden = !heat;
  element("mode-field").hidden = !inbound;
  element("inbound-fields").hidden = !inbound;
  if (advanced) {
    updateAllInputs();
    return;
  }

  const { key, data, settings } = activeView();
  const location = settings.current;
  element("mode").value = state.mode;
  element("pin").disabled = false;
  element("reset").disabled = false;
  element("scenario-warning").hidden = true;

  const profile = data.profile;
  const date = new Intl.DateTimeFormat("en-CA", { dateStyle: "medium", timeZone: "UTC" })
    .format(new Date(profile.date + "T12:00:00Z"));
  element("profile").textContent = heat
    ? profile.origin + " departure · " + date + " · " + clock(profile.minute) + " local"
    : profile.origin + " to " + profile.destination + " · " + date + " · " + profile.turn + " min scheduled turnaround";

  if (heat) {
    setRange("temperature", data.values, location.heat, value => value + " °C");
    element("support-note").textContent = "Temperature range uses " + data.support +
      " sampled flights at this departure airport, month, and time band. Other inputs are fixed.";
  } else {
    const slot = data.times[location.time];
    setRange("clock", data.times.map(time => time.minute), location.time, clock);
    setRange("prior", slot.values, location.prior, minutes);
    element("mode-note").textContent = key === "cutoff"
      ? "The inbound aircraft has already landed one hour before departure."
      : "The inbound arrival is known from historical records.";
    element("support-note").textContent = "Available inbound delays come from " + slot.support +
      " comparable flights near this departure time. Changing the time keeps the nearest supported inbound value.";
  }

  const current = curveAt(key, data, location);
  const reference = curveAt(key, data, settings.reference);
  element("scenario").textContent = "Current: " + describe(key, data, location) +
    " · Reference: " + describe(key, data, settings.reference);
  present(current, reference, data.yMax);
}

function updateAllInputs() {
  const { title, pending, message, invalid, current, reference } = state.advanced.snapshot();
  element("profile").textContent = title;
  element("support-note").textContent = pending ? "" :
    "Sliders span the middle 98% of each fitting input plus the starting value. Some combinations may be rare.";
  element("pin").disabled = Boolean(pending || invalid);
  element("reset").disabled = Boolean(pending);
  element("scenario").textContent = message;
  const warning = element("scenario-warning");
  warning.hidden = !invalid;
  warning.textContent = invalid || "";
  const peak = Math.max(0.02, ...(reference?.density || []), ...(current?.density || []));
  present(current, reference, Math.ceil(peak * 50) / 50);
}

function present(current, reference, max) {
  const value = (curve, format) => curve ? format(curve) : "—";
  const fields = {
    median: curve => minutes(curve.median),
    probability: curve => percent(curve.p30),
    interval: curve => signed(curve.q05) + " to " + minutes(curve.q95)
  };
  for (const [id, format] of Object.entries(fields)) {
    element(id).textContent = value(current, format);
    element(id + "-reference").textContent = reference ? "Reference " + value(reference, format) : "";
  }
  state.chart = { current: current?.density, reference: reference?.density, max };
  state.hover = null;
  draw();
}

function draw() {
  if (!state.chart || element("workspace").hidden) return;
  const canvas = element("density");
  const { current, reference, max } = state.chart;
  element("tooltip").hidden = true;
  const { from, to, step } = state.dataset.delay;
  const height = canvas.clientHeight;
  const width = canvas.clientWidth;
  if (!width || !height) return;
  const ratio = devicePixelRatio || 1;
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const bounds = { left: 55, right: width - 17, top: 16, bottom: height - 42 };
  const x = value => bounds.left + (value - from) / (to - from) * (bounds.right - bounds.left);
  const y = value => bounds.bottom - value / max * (bounds.bottom - bounds.top);
  ctx.font = '12px "Segoe UI", system-ui, sans-serif';
  ctx.textBaseline = "middle";
  ctx.textAlign = "right";
  for (let i = 0; i <= 4; i++) {
    const value = max * i / 4;
    ctx.strokeStyle = palette.grid;
    line(bounds.left, y(value), bounds.right, y(value));
    ctx.fillStyle = palette.axis;
    ctx.fillText(value.toFixed(3), bounds.left - 8, y(value));
  }
  ctx.textAlign = "center";
  const ticks = width < 475 ? [-30, 0, 60, 120, 180] : [-30, 0, 30, 60, 90, 120, 150, 180];
  for (const tick of ticks) ctx.fillText(signed(tick), x(tick), bounds.bottom + 14);
  ctx.fillText("Departure delay (minutes)", (bounds.left + bounds.right) / 2, height - 7);
  ctx.save();
  ctx.translate(9, (bounds.top + bounds.bottom) / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.fillText("Density", 0, 0);
  ctx.restore();

  ctx.strokeStyle = "#9cb0b6";
  ctx.setLineDash([3, 4]);
  line(x(0), bounds.top, x(0), bounds.bottom);
  ctx.setLineDash([]);

  if (current) {
    trace(current);
    ctx.lineTo(x(to), bounds.bottom);
    ctx.lineTo(x(from), bounds.bottom);
    ctx.closePath();
    ctx.fillStyle = "#08796f14";
    ctx.fill();
    ctx.lineWidth = 2.6;
    ctx.strokeStyle = palette.current;
    trace(current);
    ctx.stroke();
  }
  if (reference) {
    ctx.strokeStyle = palette.reference;
    ctx.setLineDash([6, 5]);
    ctx.lineWidth = 1.65;
    trace(reference);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  const tip = element("tooltip");
  if (!current || !reference || state.hover === null || state.hover < bounds.left || state.hover > bounds.right) {
    tip.hidden = true;
    return;
  }
  const index = Math.round((state.hover - bounds.left) / (bounds.right - bounds.left) * (current.length - 1));
  const minute = from + index * step;
  const cursor = x(minute);
  ctx.strokeStyle = "#72888e";
  ctx.lineWidth = 1;
  line(cursor, bounds.top, cursor, bounds.bottom);
  ctx.fillStyle = palette.current;
  ctx.beginPath();
  ctx.arc(cursor, y(current[index]), 3.5, 0, 2 * Math.PI);
  ctx.fill();
  tip.textContent = minutes(minute) + "\nCurrent density " + current[index].toFixed(4) +
    "\nReference density " + reference[index].toFixed(4);
  tip.hidden = false;
  tip.style.left = Math.max(0, Math.min(cursor + 10, width - tip.offsetWidth)) + "px";
  tip.style.top = bounds.top + 5 + "px";

  function line(x1, y1, x2, y2) {
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
  }

  function trace(values) {
    ctx.beginPath();
    ctx.moveTo(x(from), y(values[0]));
    values.forEach((value, i) => ctx.lineTo(x(from + step * i), y(value)));
  }
}

function bind() {
  for (const question of ["heat", "inbound"]) {
    element(question + "-tab").addEventListener("click", () => { state.question = question; update(); });
  }
  element("all-tab").addEventListener("click", () => {
    state.question = "all";
    state.advanced.select(element("all-model").value);
  });
  element("all-model").addEventListener("change", event => state.advanced.select(event.target.value));
  element("mode").addEventListener("change", event => { state.mode = event.target.value; update(); });
  element("temperature").addEventListener("input", event => {
    state.views.heat.current.heat = Number(event.target.value);
    update();
  });
  element("clock").addEventListener("input", event => {
    const { data, settings } = activeView();
    const location = settings.current;
    const prior = data.times[location.time].values[location.prior];
    location.time = Number(event.target.value);
    location.prior = nearest(data.times[location.time].values, prior);
    update();
  });
  element("prior").addEventListener("input", event => {
    activeView().settings.current.prior = Number(event.target.value);
    update();
  });
  element("pin").addEventListener("click", () => {
    if (state.question === "all") return state.advanced.pin();
    const { settings } = activeView();
    settings.reference = { ...settings.current };
    update();
  });
  element("reset").addEventListener("click", () => {
    if (state.question === "all") return state.advanced.reset();
    const { key, settings } = activeView();
    settings.current = initial(key);
    settings.reference = initial(key);
    update();
  });
  element("density").addEventListener("pointermove", event => {
    if (event.pointerType === "touch") return;
    state.hover = event.offsetX;
    draw();
  });
  element("density").addEventListener("pointerleave", () => { state.hover = null; draw(); });
  new ResizeObserver(draw).observe(element("chart"));
}

async function load() {
  try {
    const response = await fetch("./delay-data.json");
    if (!response.ok) throw new Error("Forest predictions returned HTTP " + response.status);
    state.dataset = await response.json();
    for (const key of ["heat", "rotation", "cutoff"]) {
      state.views[key] = { current: initial(key), reference: initial(key) };
      state.dataset[key].yMax = yScale(key);
    }
    state.advanced = createForestControls({
      container: element("all-controls"), onChange: update, grid: state.dataset.delay,
      bandwidth: state.dataset.bandwidth, clock
    });
    bind();
    element("workspace").hidden = false;
    element("status").hidden = true;
    update();
  } catch (error) {
    console.error(error);
    element("status").hidden = false;
    element("status").textContent = "The forest predictions could not be loaded. Try reloading the page.";
  }
}

load();
