const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

test("website guide follows the recording workflow and highlights the relevant steps", () => {
  const ids = [
    "guide-panel", "guide-toggle", "coach-title", "coach-message", "coach-guide", "guide-close",
    "guide-step-title", "guide-step-text", "guide-step-tip", "guide-progress", "guide-progress-fill",
    "guide-visual", "guide-back", "guide-next", "guide-play", "guide-replay", "guide-go",
    "status", "samples", "gaps", "rate", "folder-status", "connect", "stop", "subject",
    "activity", "duration", "folder", "graph"
  ];
  function element() {
    const classes = new Set();
    const handlers = {};
    return {
      textContent: "", value: "", disabled: false, hidden: false,
      style: {}, dataset: {}, offsetWidth: 100,
      classList: {
        add: name => classes.add(name), remove: name => classes.delete(name),
        contains: name => classes.has(name)
      },
      addEventListener: (name, handler) => { handlers[name] = handler; },
      click: () => handlers.click?.(),
      setAttribute() {}, scrollIntoView() {}, focus() {}
    };
  }
  const els = Object.fromEntries(ids.map(id => [id, element()]));
  const demo = Array.from({ length: 6 }, element);
  const intervals = [];
  els["guide-panel"].hidden = true;
  els["stop"].disabled = true;
  els["connect"].textContent = "Connect and record";
  els["folder-status"].textContent = "No save folder chosen.";
  els["samples"].textContent = "0";
  els["gaps"].textContent = "0";
  const context = vm.createContext({
    document: {
      getElementById: id => els[id],
      querySelectorAll: selector => selector === ".guide-demo-item"
        ? demo : [...Object.values(els), ...demo].filter(item => item.classList.contains("guide-target"))
    },
    MutationObserver: class { observe() {} },
    setInterval: callback => (intervals.push(callback), intervals.length),
    clearInterval() {}, setTimeout: () => 1, clearTimeout() {}
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../docs/guide.js"), "utf8"), context);
  const update = intervals[0];
  assert.equal(els["coach-title"].textContent, "Choose where to save");
  els["guide-toggle"].click();
  assert.equal(els["guide-panel"].hidden, false);
  assert.equal(els["guide-step-title"].textContent, "Choose a save folder");
  assert.equal(demo[0].classList.contains("is-active"), true);
  els["guide-next"].click();
  assert.equal(els["guide-step-title"].textContent, "Enter the test details");
  assert.equal(demo[1].classList.contains("is-active"), true);

  els["folder-status"].textContent = "Automatic save: recordings/P01/action/";
  els["subject"].value = "P01";
  update();
  assert.equal(els["coach-title"].textContent, "Ready to connect");
  els["stop"].disabled = false;
  els["connect"].disabled = true;
  update();
  assert.equal(els["coach-title"].textContent, "Recording is in progress");
  els["samples"].textContent = "120";
  els["gaps"].textContent = "1";
  update();
  assert.equal(els["coach-title"].textContent, "Recording with data gaps");

  els["stop"].disabled = true;
  els["connect"].disabled = false;
  els["connect"].textContent = "Start next test";
  els["status"].textContent = "Stopped. Saved CSV and graph in recordings/P01/action/.";
  update();
  assert.equal(els["coach-title"].textContent, "Ready for another test");
  els["status"].textContent = "Stopped. Download the CSV and graph to save this session.";
  update();
  assert.equal(els["coach-title"].textContent, "Save this test before continuing");
  els["status"].textContent = "ESP32 disconnected. The last test is still available on this page.";
  els["connect"].textContent = "Connect and record";
  update();
  assert.equal(els["coach-title"].textContent, "Previous test is displayed");
});
