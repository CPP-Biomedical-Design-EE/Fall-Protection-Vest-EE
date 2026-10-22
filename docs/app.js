"use strict";

const FIELDS = [
  "timestamp_utc", "elapsed_s", "label", "event_class", "placement", "subject_id",
  "ax", "ay", "az", "gx", "gy", "gz", "acceleration_unit", "gyroscope_unit",
  "input_format", "device_time_us", "sequence", "device_elapsed_s", "sample_interval_s",
  "stream_discontinuity", "euler_x_deg", "euler_y_deg", "euler_z_deg"
];
const G = 9.80665;
const RAD_TO_DEG = 180 / Math.PI;
const els = Object.fromEntries([
  "subject", "activity", "activity-guidance", "label", "event-class", "duration", "connect", "stop", "csv", "png",
  "status", "samples", "elapsed", "rate", "gaps", "total", "graph", "hover"
].map(id => [id, document.getElementById(id)]));
const canvas = els.graph;
const ctx = canvas.getContext("2d");
let port = null;
let reader = null;
let running = false;
let rows = [];
let previous = null;
let deviceElapsed = 0;
let yaw = 0;
let gapCount = 0;
let intervals = [];
let firstHostMs = null;
let lastDrawMs = 0;
let showAll = false;
let hoverX = null;
let session = null;

function setStatus(message, error = false) {
  els.status.textContent = message;
  els.status.classList.toggle("error", error);
}

function validLabel(value) {
  return /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value);
}

function updateSavedLabels() {
  if (running || !rows.length || !session) return;
  const valid = validLabel(els.label.value.trim());
  els.csv.disabled = !valid;
  els.png.disabled = !valid;
  if (!valid) return;
  session.label = els.label.value.trim();
  session.eventClass = els["event-class"].value;
  for (const row of rows) {
    row.label = session.label;
    row.event_class = session.eventClass;
  }
}

function selectActivity() {
  const label = els.activity.value;
  const custom = label === "custom";
  els.label.readOnly = !custom;
  els["event-class"].disabled = running || !custom;
  if (!custom) {
    els.label.value = label;
    els["event-class"].value = label.split("_")[0];
  } else {
    els.label.value = "";
    els.label.focus();
  }
  els["activity-guidance"].textContent = label.startsWith("fall_")
    ? "Use this label only for an actual confirmed fall under an approved, supervised protocol. Do not deliberately create an unsafe fall."
    : custom
      ? "Enter a short label, then choose its event class. Use letters, numbers, underscores or hyphens."
      : "Choose the action actually performed. You can correct the selection after recording, before downloading the CSV.";
  updateSavedLabels();
}

function csvCell(value) {
  const text = String(value ?? "");
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function parseLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#") ||
      trimmed.toLowerCase().replaceAll(" ", "") === "device_time_us,sequence,ax,ay,az,gx,gy,gz") return null;
  const fields = trimmed.split(",").map(value => value.trim());
  if (fields.length !== 8 || !/^\d+$/.test(fields[0]) || !/^\d+$/.test(fields[1])) return null;
  const timestamp = Number(fields[0]);
  const sequence = Number(fields[1]);
  const values = fields.slice(2).map(Number);
  if (!Number.isSafeInteger(timestamp) || timestamp < 0 || timestamp >= 2 ** 32 ||
      !Number.isSafeInteger(sequence) || sequence < 0 || sequence >= 2 ** 32 ||
      fields.slice(2).some(value => value === "") || values.some(value => !Number.isFinite(value))) return null;
  return { timestamp, sequence, values };
}

function addSample(sample) {
  const now = performance.now();
  if (firstHostMs === null) firstHostMs = now;
  const elapsed = (now - firstHostMs) / 1000;
  let interval = null;
  let discontinuity = false;
  if (previous !== null) {
    const deltaUs = (sample.timestamp - previous.timestamp + 2 ** 32) % (2 ** 32);
    const deltaSeq = (sample.sequence - previous.sequence + 2 ** 32) % (2 ** 32);
    discontinuity = deltaSeq !== 1 || deltaUs < 5000 || deltaUs > 15000;
    if (!discontinuity) {
      interval = deltaUs / 1e6;
      deviceElapsed += interval;
      intervals.push(interval);
      if (intervals.length > 500) intervals.shift();
    } else {
      gapCount++;
      intervals = [];
    }
  }
  const [ax, ay, az, gx, gy, gz] = sample.values;
  const roll = Math.hypot(ay, az) < 1e-6 ? "" : Math.atan2(ay, az) * RAD_TO_DEG;
  const pitch = Math.atan2(-ax, Math.hypot(ay, az)) * RAD_TO_DEG;
  if (interval !== null) yaw += gz * interval * RAD_TO_DEG;
  const magnitude = Math.hypot(ax, ay, az) / G;
  const row = {
    timestamp_utc: new Date().toISOString(), elapsed_s: elapsed.toFixed(6),
    label: session.label, event_class: session.eventClass,
    placement: "lower_back_center_waist", subject_id: session.subject,
    ax, ay, az, gx, gy, gz,
    acceleration_unit: "m/s^2", gyroscope_unit: "rad/s", input_format: "timestamped",
    device_time_us: sample.timestamp, sequence: sample.sequence,
    device_elapsed_s: deviceElapsed.toFixed(6), sample_interval_s: interval === null ? "" : interval.toFixed(6),
    stream_discontinuity: Number(discontinuity), euler_x_deg: roll === "" ? "" : roll.toFixed(6),
    euler_y_deg: pitch.toFixed(6), euler_z_deg: yaw.toFixed(6),
    magnitude, gyroDps: [gx, gy, gz].map(value => value * RAD_TO_DEG), elapsed
  };
  rows.push(row);
  previous = sample;
  els.samples.textContent = String(rows.length);
  els.elapsed.textContent = `${elapsed.toFixed(1)} s`;
  els.gaps.textContent = String(gapCount);
  els.total.textContent = `${magnitude.toFixed(2)} g`;
  if (intervals.length >= 10) {
    const hz = intervals.length / intervals.reduce((sum, value) => sum + value, 0);
    els.rate.textContent = `${hz.toFixed(1)} Hz`;
  }
  if (now - lastDrawMs > 100) {
    lastDrawMs = now;
    requestAnimationFrame(drawGraph);
  }
  if (elapsed >= session.duration) void stopCapture();
}

function visibleRows() {
  if (!rows.length) return { data: [], left: 0, right: 20 };
  const right = Math.max(20, rows.at(-1).elapsed);
  const left = showAll ? 0 : Math.max(0, right - 20);
  return { data: rows.filter(row => row.elapsed >= left), left, right };
}

function drawGraph() {
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, width, height);
  const { data, left, right } = visibleRows();
  const marginLeft = 82;
  const marginRight = 20;
  const plotWidth = width - marginLeft - marginRight;
  const panels = [
    { y: 38, h: 155, title: "Acceleration (m/s²)", keys: ["ax", "ay", "az"], labels: ["Ax", "Ay", "Az"] },
    { y: 222, h: 155, title: "Gyroscope (°/s)", keys: ["gx", "gy", "gz"], labels: ["Gx", "Gy", "Gz"], gyro: true },
    { y: 406, h: 135, title: "Total acceleration (g)", keys: ["magnitude"], labels: ["Total"] },
    { y: 570, h: 135, title: "Estimated X/Y tilt, relative Z yaw (°)", keys: ["euler_x_deg", "euler_y_deg", "euler_z_deg"], labels: ["X", "Y", "Z"] }
  ];
  const colors = ["#2674b8", "#d85944", "#22865e"];
  const xFor = row => marginLeft + (row.elapsed - left) / Math.max(1, right - left) * plotWidth;
  for (const panel of panels) {
    let min = Infinity;
    let max = -Infinity;
    for (const row of data) {
      panel.keys.forEach((key, index) => {
        if (row[key] === "") return;
        const value = panel.gyro ? row.gyroDps[index] : Number(row[key]);
        if (Number.isFinite(value)) { min = Math.min(min, value); max = Math.max(max, value); }
      });
    }
    if (panel.keys[0] === "magnitude") { min = Math.min(min, 1); max = Math.max(max, 1); }
    if (!Number.isFinite(min)) { min = -1; max = 1; }
    if (min === max) { min -= 1; max += 1; }
    const pad = (max - min) * .12;
    min -= pad; max += pad;
    const yFor = value => panel.y + panel.h - (value - min) / (max - min) * panel.h;
    ctx.fillStyle = "#f8fbfc";
    ctx.fillRect(marginLeft, panel.y, plotWidth, panel.h);
    ctx.strokeStyle = "#dae4e8";
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const x = marginLeft + i * plotWidth / 4;
      const y = panel.y + i * panel.h / 4;
      ctx.beginPath(); ctx.moveTo(x, panel.y); ctx.lineTo(x, panel.y + panel.h); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(marginLeft, y); ctx.lineTo(width - marginRight, y); ctx.stroke();
    }
    ctx.font = "14px system-ui";
    ctx.fillStyle = "#172b3a";
    ctx.fillText(panel.title, marginLeft, panel.y - 11);
    ctx.font = "12px system-ui";
    ctx.fillStyle = "#526674";
    ctx.fillText(max.toFixed(1), 32, panel.y + 5);
    ctx.fillText(min.toFixed(1), 32, panel.y + panel.h);
    if (panel.keys[0] === "magnitude") {
      ctx.setLineDash([5, 5]); ctx.strokeStyle = "#7f8990";
      ctx.beginPath(); ctx.moveTo(marginLeft, yFor(1)); ctx.lineTo(width - marginRight, yFor(1)); ctx.stroke();
      ctx.setLineDash([]);
    }
    panel.keys.forEach((key, index) => {
      ctx.strokeStyle = panel.keys.length === 1 ? "#7451ac" : colors[index];
      ctx.lineWidth = 1.8;
      ctx.beginPath();
      let started = false;
      for (const row of data) {
        const value = panel.gyro ? row.gyroDps[index] : Number(row[key]);
        if (!Number.isFinite(value) || row[key] === "") { started = false; continue; }
        const x = xFor(row), y = yFor(value);
        if (started) ctx.lineTo(x, y); else ctx.moveTo(x, y);
        started = true;
      }
      ctx.stroke();
      ctx.fillStyle = ctx.strokeStyle;
      ctx.fillText(panel.labels[index], width - 155 + index * 45, panel.y - 11);
    });
    if (hoverX !== null && hoverX >= marginLeft && hoverX <= width - marginRight) {
      ctx.strokeStyle = "#617888"; ctx.setLineDash([3, 4]);
      ctx.beginPath(); ctx.moveTo(hoverX, panel.y); ctx.lineTo(hoverX, panel.y + panel.h); ctx.stroke();
      ctx.setLineDash([]);
    }
  }
  ctx.fillStyle = "#526674"; ctx.font = "12px system-ui";
  for (let i = 0; i <= 4; i++) {
    const t = left + i * (right - left) / 4;
    ctx.fillText(`${t.toFixed(1)} s`, marginLeft + i * plotWidth / 4 - 15, height - 24);
  }
  ctx.fillText("Elapsed time from recording start", width / 2 - 96, height - 5);
}

async function readSerial() {
  const decoder = new TextDecoder();
  let pending = "";
  try {
    while (running && port?.readable) {
      reader = port.readable.getReader();
      try {
        while (running) {
          const result = await reader.read();
          if (result.done) break;
          pending += decoder.decode(result.value, { stream: true });
          if (pending.length > 16384) pending = pending.slice(-8192);
          let end;
          while ((end = pending.indexOf("\n")) >= 0) {
            const line = pending.slice(0, end);
            pending = pending.slice(end + 1);
            const sample = parseLine(line);
            if (sample) addSample(sample);
            if (!running) break;
          }
        }
      } finally {
        reader.releaseLock();
        reader = null;
      }
      break;
    }
  } catch (error) {
    if (running) setStatus(`Serial connection stopped: ${error.message}`, true);
  } finally {
    running = false;
    try { if (port) await port.close(); } catch { /* Browser may close an unplugged port. */ }
    port = null;
    showAll = true;
    drawGraph();
    els.connect.disabled = false;
    els.stop.disabled = true;
    els.csv.disabled = rows.length === 0;
    els.png.disabled = rows.length === 0;
    [els.subject, els.activity, els.label, els.duration].forEach(element => { element.disabled = false; });
    els["event-class"].disabled = els.activity.value !== "custom";
    if (!els.status.classList.contains("error")) {
      const seconds = rows.length ? rows.at(-1).elapsed : 0;
      const hz = intervals.length ? intervals.length / intervals.reduce((sum, value) => sum + value, 0) : 0;
      const quality = rows.length >= 101 && gapCount === 0 && hz >= 95 && hz <= 105
        ? "100 Hz timing check passed" : "100 Hz timing not verified";
      setStatus(`Stopped: ${rows.length} samples, ${seconds.toFixed(1)} s. ${quality}. Download the CSV to save this session.`);
    }
  }
}

async function connect() {
  if (!("serial" in navigator)) {
    setStatus("Web Serial is unavailable. Open this HTTPS page in Chrome or Edge on a desktop computer.", true);
    return;
  }
  const subject = els.subject.value.trim();
  const label = els.label.value.trim();
  const duration = Number(els.duration.value);
  if (!validLabel(subject) || !validLabel(label) || !Number.isFinite(duration) || duration < 1 || duration > 600) {
    setStatus("Use IDs and labels with letters, numbers, underscores or hyphens; duration must be 1–600 seconds.", true);
    return;
  }
  try {
    port = await navigator.serial.requestPort();
    await port.open({ baudRate: 115200 });
    session = { subject, label, eventClass: els["event-class"].value, duration };
    rows = []; previous = null; deviceElapsed = 0; yaw = 0; gapCount = 0;
    intervals = []; firstHostMs = null; showAll = false; hoverX = null;
    els.samples.textContent = "0"; els.elapsed.textContent = "0.0 s";
    els.rate.textContent = "—"; els.gaps.textContent = "0"; els.total.textContent = "—";
    els.csv.disabled = true; els.png.disabled = true;
    els.connect.disabled = true; els.stop.disabled = false;
    [els.subject, els.activity, els.label, els["event-class"], els.duration].forEach(element => { element.disabled = true; });
    running = true;
    setStatus("Connected. Waiting for the first timestamped sensor sample…");
    drawGraph();
    void readSerial();
  } catch (error) {
    if (port) { try { await port.close(); } catch { /* Already closed. */ } port = null; }
    setStatus(error.name === "NotFoundError" ? "No port selected." : `Could not connect: ${error.message}`, true);
  }
}

async function stopCapture() {
  if (!running) return;
  running = false;
  if (reader) { try { await reader.cancel(); } catch { /* Read loop will close the port. */ } }
}

function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url; link.download = filename;
  document.body.append(link);
  link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function filename(suffix) {
  const stamp = new Date().toISOString().replace(/[-:.]/g, "").slice(0, 15);
  return `${session.label}_${session.subject}_lower_back_center_waist_${stamp}_${suffix}`;
}

els.connect.addEventListener("click", connect);
els.stop.addEventListener("click", () => { void stopCapture(); });
els.activity.addEventListener("change", selectActivity);
els.label.addEventListener("change", updateSavedLabels);
els["event-class"].addEventListener("change", updateSavedLabels);
els.csv.addEventListener("click", () => {
  if (!rows.length) return;
  const data = [FIELDS.join(","), ...rows.map(row => FIELDS.map(key => csvCell(row[key])).join(","))].join("\r\n") + "\r\n";
  downloadBlob(new Blob([data], { type: "text/csv;charset=utf-8" }), filename("raw.csv"));
});
els.png.addEventListener("click", () => {
  if (!rows.length) return;
  drawGraph();
  canvas.toBlob(blob => { if (blob) downloadBlob(blob, filename("graph.png")); });
});
canvas.addEventListener("mousemove", event => {
  if (!rows.length) return;
  const rect = canvas.getBoundingClientRect();
  hoverX = (event.clientX - rect.left) * canvas.width / rect.width;
  const { data, left, right } = visibleRows();
  const time = left + (hoverX - 82) / (canvas.width - 102) * (right - left);
  const row = data.reduce((best, item) => !best || Math.abs(item.elapsed - time) < Math.abs(best.elapsed - time) ? item : best, null);
  if (row) {
    els.hover.textContent = `t=${row.elapsed.toFixed(3)} s  |  ${row.timestamp_utc}\n` +
      `A: ${[row.ax, row.ay, row.az].map(value => Number(value).toFixed(3)).join(", ")} m/s²  |  Total: ${row.magnitude.toFixed(3)} g\n` +
      `G: ${row.gyroDps.map(value => value.toFixed(1)).join(", ")} °/s  |  X/Y/Z: ${[row.euler_x_deg, row.euler_y_deg, row.euler_z_deg].join(", ")}°`;
  }
  drawGraph();
});
canvas.addEventListener("mouseleave", () => { hoverX = null; drawGraph(); });
if (!("serial" in navigator)) {
  setStatus("Open this HTTPS page in Chrome or Edge on a desktop computer to connect the ESP32.", true);
}
selectActivity();
drawGraph();
