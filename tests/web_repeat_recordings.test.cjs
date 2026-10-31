const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function makePage({ granted = false, confirm = () => true } = {}) {
  const saved = new Map();
  const root = {
    name: "recordings",
    async getDirectoryHandle(name) {
      return {
        async getDirectoryHandle(action) {
          return {
            async getFileHandle(file) {
              return {
                async createWritable() {
                  return {
                    async write(value) { saved.set(`${name}/${action}/${file}`, value); },
                    async close() {},
                    async abort() {}
                  };
                }
              };
            }
          };
        }
      };
    }
  };
  const queue = [];
  let waiting = null;
  let cancelled = false;
  const reader = {
    read() {
      if (queue.length) return Promise.resolve(queue.shift());
      if (cancelled) return Promise.resolve({ done: true });
      return new Promise(resolve => { waiting = resolve; });
    },
    async cancel() {
      cancelled = true;
      if (waiting) { waiting({ done: true }); waiting = null; }
    },
    releaseLock() {}
  };
  const port = {
    openCount: 0,
    closeCount: 0,
    readable: { getReader: () => reader },
    async open() { this.openCount++; },
    async close() { this.closeCount++; }
  };
  let requestCount = 0;
  const serial = {
    async getPorts() { return granted ? [port] : []; },
    async requestPort() { requestCount++; return port; }
  };
  const context2d = new Proxy({ measureText: text => ({ width: text.length * 7 }) }, {
    get(target, key) { return key in target ? target[key] : () => {}; }
  });
  const elements = {};
  for (const id of [
    "subject", "activity", "activity-guidance", "label", "event-class", "duration", "folder", "folder-status",
    "connect", "stop", "reset", "disconnect", "csv", "png", "status", "samples", "elapsed", "rate",
    "gaps", "total", "graph", "hover"
  ]) {
    elements[id] = {
      value: "", textContent: "", disabled: false, readOnly: false,
      classList: { toggle() {} }, addEventListener() {}, focus() {}
    };
  }
  elements.subject.value = "P01";
  elements.activity.value = "adl_T01_standing";
  elements.duration.value = "30";
  elements.graph.width = 1160;
  elements.graph.height = 760;
  elements.graph.getContext = () => context2d;
  elements.graph.toBlob = callback => callback(new Blob(["graph"]));
  const context = vm.createContext({
    document: { getElementById: id => elements[id] },
    navigator: { serial },
    window: { confirm, showDirectoryPicker: async () => root },
    TextDecoder, Blob, performance: { now: (() => { let t = 0; return () => (t += 10); })() },
    requestAnimationFrame: callback => callback()
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../docs/app.js"), "utf8"), context);
  function feed(sequence) {
    const line = `${1000000 + sequence * 10000},${sequence},0,9.80665,0,0,0,0\n`;
    const item = { done: false, value: new TextEncoder().encode(line) };
    if (waiting) { waiting(item); waiting = null; } else queue.push(item);
  }
  function unplug() {
    cancelled = true;
    if (waiting) { waiting({ done: true }); waiting = null; }
  }
  return { context, elements, saved, port, feed, unplug, get requestCount() { return requestCount; } };
}

test("a connected ESP32 supports repeated saved trials without another port chooser", async () => {
  const page = makePage();
  await page.context.chooseSaveFolder();
  await page.context.connect();
  page.feed(1);
  await new Promise(setImmediate);
  await page.context.stopCapture();
  assert.equal(page.port.closeCount, 0);
  assert.equal(page.elements.connect.textContent, "Start next test");
  assert.equal(page.saved.size, 2);

  page.elements.activity.value = "adl_T02_tie_shoes";
  page.context.selectActivity();
  await page.context.connect();
  page.feed(2);
  await new Promise(setImmediate);
  await page.context.stopCapture();
  assert.equal(page.requestCount, 1);
  assert.equal(page.port.openCount, 1);
  assert.equal(page.port.closeCount, 0);
  assert.equal(page.saved.size, 4);
  assert.ok([...page.saved.keys()].some(key => key.startsWith("P01/adl_T01_standing/") && key.endsWith(".csv")));
  assert.ok([...page.saved.keys()].some(key => key.startsWith("P01/adl_T02_tie_shoes/") && key.endsWith(".csv")));

  page.context.resetSession();
  assert.equal(page.elements.connect.textContent, "Start next test");
  await page.context.connect();
  assert.equal(page.requestCount, 1);
  await page.context.stopCapture();
  await page.context.disconnectPort();
  await new Promise(setImmediate);
  assert.equal(page.port.closeCount, 1);
  assert.equal(page.elements.connect.textContent, "Connect and record");
});

test("a previously approved port can be reused after a page reload", async () => {
  const page = makePage({ granted: true });
  await page.context.connect();
  assert.equal(page.requestCount, 0);
  assert.equal(page.port.openCount, 1);
  await page.context.stopCapture();
  await page.context.disconnectPort();
});

test("an unexpected serial disconnect saves the active trial", async () => {
  const page = makePage();
  await page.context.chooseSaveFolder();
  await page.context.connect();
  page.feed(1);
  await new Promise(setImmediate);
  page.unplug();
  await new Promise(setImmediate);
  assert.equal(page.saved.size, 2);
  assert.equal(page.port.closeCount, 1);
  assert.equal(page.elements.connect.textContent, "Connect and record");
  assert.match(page.elements.status.textContent, /disconnected unexpectedly/);
});

test("starting another trial asks before discarding data without automatic saving", async () => {
  const page = makePage({ confirm: () => false });
  await page.context.connect();
  page.feed(1);
  await new Promise(setImmediate);
  await page.context.stopCapture();
  await page.context.connect();
  assert.equal(page.elements.samples.textContent, "1");
  assert.equal(page.requestCount, 1);
  assert.equal(page.port.closeCount, 0);
  await page.context.disconnectPort();
});
