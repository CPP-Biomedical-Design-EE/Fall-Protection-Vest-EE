"use strict";

(() => {
  const byId = id => document.getElementById(id);
  const panel = byId("guide-panel");
  const toggle = byId("guide-toggle");
  const steps = [
    {
      title: "Choose a save folder",
      text: "Click Choose save folder and select a folder on this computer. After each test, the website will save a CSV and graph PNG inside a participant and action folder.",
      tip: "Choose it once for this page session. Without a folder, use the download buttons after every test.",
      target: "folder"
    },
    {
      title: "Enter the test details",
      text: "Enter a participant ID, choose the action the participant will actually perform, and set the duration. The saved label updates when you choose an action.",
      tip: "Use an ID such as P01 instead of a participant's name if you want to keep identities separate from the recordings.",
      target: "subject"
    },
    {
      title: "Connect and start recording",
      text: "Connect the ESP32 with a USB data cable, close Arduino Serial Monitor, then click Connect and record. If Chrome or Edge asks for a port, choose the USB serial device.",
      tip: "The browser normally keeps the selected port connected between tests on this page.",
      target: "connect"
    },
    {
      title: "Watch the live test",
      text: "Check that Samples increases and the graph moves. Watch Device rate and Sequence gaps while the chosen action is performed. Move the mouse over the graph to inspect a sample.",
      tip: "If samples stay at zero, check that the ESP32 is streaming and no other program has its serial port open.",
      target: "graph"
    },
    {
      title: "Stop and save",
      text: "Click Stop when the trial ends, or let the duration stop it. The page reports the timing check and saves the CSV and graph PNG automatically if you chose a folder.",
      tip: "If automatic saving fails, use Download last CSV and Download last graph PNG before starting again.",
      target: "stop"
    },
    {
      title: "Start the next test",
      text: "Choose the next action and click Start next test. This clears the displayed graph and starts a new recording using the same ESP32 connection and save folder.",
      tip: "Clear last graph is optional. Click Disconnect ESP32 when you are finished or want to change the port.",
      target: "connect"
    }
  ];
  let step = 0;
  let playTimer = null;
  let highlightTimer = null;
  let recordingSince = null;
  let wasRecording = false;
  let suggestedStep = 0;

  function stopPlaying() {
    if (playTimer !== null) clearInterval(playTimer);
    playTimer = null;
    byId("guide-play").textContent = "Play guide";
  }

  function renderStep() {
    const current = steps[step];
    byId("guide-step-title").textContent = current.title;
    byId("guide-step-text").textContent = current.text;
    byId("guide-step-tip").textContent = current.tip;
    byId("guide-progress").textContent = `Step ${step + 1} of ${steps.length}`;
    byId("guide-progress-fill").style.width = `${(step + 1) / steps.length * 100}%`;
    byId("guide-visual").dataset.step = String(step);
    byId("guide-back").disabled = step === 0;
    byId("guide-next").disabled = step === steps.length - 1;
    document.querySelectorAll(".guide-demo-item").forEach((item, index) => {
      item.classList.remove("is-active");
      if (index === step) {
        void item.offsetWidth;
        item.classList.add("is-active");
      }
    });
  }

  function setStep(next) {
    step = Math.max(0, Math.min(steps.length - 1, next));
    renderStep();
    if (step === steps.length - 1) stopPlaying();
  }

  function openGuide(next = suggestedStep) {
    panel.hidden = false;
    toggle.textContent = "Hide guide";
    toggle.setAttribute("aria-expanded", "true");
    setStep(next);
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function closeGuide() {
    stopPlaying();
    panel.hidden = true;
    toggle.textContent = "Guide me";
    toggle.setAttribute("aria-expanded", "false");
    toggle.focus();
  }

  function showTarget() {
    const target = byId(steps[step].target);
    if (!target) return;
    clearTimeout(highlightTimer);
    document.querySelectorAll(".guide-target").forEach(item => item.classList.remove("guide-target"));
    target.classList.add("guide-target");
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    if (typeof target.focus === "function" && !target.disabled && target.id !== "graph") {
      target.focus({ preventScroll: true });
    }
    highlightTimer = setTimeout(() => target.classList.remove("guide-target"), 4000);
  }

  function coachState() {
    const status = byId("status").textContent;
    const samples = Number(byId("samples").textContent) || 0;
    const gaps = Number(byId("gaps").textContent) || 0;
    const rate = Number.parseFloat(byId("rate").textContent);
    const recording = !byId("stop").disabled;
    if (recording && !wasRecording) recordingSince = Date.now();
    if (!recording) recordingSince = null;
    wasRecording = recording;

    if (recording) {
      suggestedStep = 3;
      if (samples === 0 && Date.now() - recordingSince > 3000) {
        return ["Waiting for sensor data", "Samples is still zero. Check the USB connection, firmware, and whether another app has the serial port open."];
      }
      if (gaps > 0) return ["Recording with data gaps", "Sequence gaps were detected. Finish this trial, then check the connection before relying on the data."];
      if (samples >= 101 && Number.isFinite(rate) && (rate < 95 || rate > 105)) {
        return ["Check the sample rate", `The displayed device rate is ${rate.toFixed(1)} Hz. The final timing check appears after the test stops.`];
      }
      return ["Recording is in progress", samples
        ? `${samples} samples received. Perform the selected action, then click Stop or wait for the duration to finish.`
        : "Waiting for the first sensor sample. The graph will move when data arrives."];
    }
    if (samples && (/Automatic save failed/i.test(status) || /Download the CSV and graph/i.test(status))) {
      suggestedStep = 4;
      return ["Save this test before continuing", "Download the last CSV and graph PNG. Starting a new test will replace the displayed recording."];
    }
    if (byId("connect").disabled) {
      suggestedStep = 4;
      return /Disconnecting ESP32/i.test(status)
        ? ["Disconnecting ESP32", "Wait for the device to disconnect before choosing another port."]
        : ["Finishing this test", "Wait while the recording stops and its files are saved."];
    }
    if (/No port selected/i.test(status)) {
      suggestedStep = 2;
      return ["Choose the USB port", "Click Connect and record again, then select your ESP32's USB serial port in the browser window."];
    }
    if (/Could not connect|Web Serial is unavailable|Serial connection stopped/i.test(status)) {
      suggestedStep = 2;
      return ["Connection needs attention", "Check the USB cable, close Arduino Serial Monitor, then try Connect and record again."];
    }
    if (byId("connect").textContent === "Start next test") {
      suggestedStep = 5;
      return ["Ready for another test", "The graph shows the previous test. Choose the next action and click Start next test to see fresh ESP32 readings."];
    }
    if (samples > 0) {
      suggestedStep = 2;
      return ["Previous test is displayed", "The graph and acceleration numbers are from the last test. Connect and record to see fresh sensor readings."];
    }
    if (!byId("folder-status").textContent.startsWith("Automatic save:")) {
      suggestedStep = 0;
      return ["Choose where to save", "Click Choose save folder for automatic CSV and graph saving. You can also download each file manually after a test."];
    }
    if (!byId("subject").value.trim()) {
      suggestedStep = 1;
      return ["Enter a participant ID", "Add an ID such as P01, then choose the action and duration."];
    }
    suggestedStep = 2;
    return ["Ready to connect", "Choose the action and duration, then click Connect and record. Select the USB serial device if the browser asks."];
  }

  function updateCoach() {
    const [title, message] = coachState();
    if (byId("coach-title").textContent !== title) byId("coach-title").textContent = title;
    if (byId("coach-message").textContent !== message) byId("coach-message").textContent = message;
  }

  toggle.addEventListener("click", () => panel.hidden ? openGuide() : closeGuide());
  byId("coach-guide").addEventListener("click", () => openGuide());
  byId("guide-close").addEventListener("click", closeGuide);
  byId("guide-back").addEventListener("click", () => setStep(step - 1));
  byId("guide-next").addEventListener("click", () => setStep(step + 1));
  byId("guide-replay").addEventListener("click", renderStep);
  byId("guide-go").addEventListener("click", showTarget);
  byId("guide-play").addEventListener("click", () => {
    if (playTimer !== null) { stopPlaying(); return; }
    if (step === steps.length - 1) setStep(0);
    byId("guide-play").textContent = "Pause guide";
    playTimer = setInterval(() => setStep(step + 1), 5000);
  });
  ["status", "samples", "gaps", "rate", "folder-status", "connect", "stop"].forEach(id => {
    new MutationObserver(updateCoach).observe(byId(id), { childList: true, characterData: true, subtree: true, attributes: true, attributeFilter: ["disabled", "class"] });
  });
  byId("subject").addEventListener("input", updateCoach);
  byId("activity").addEventListener("change", updateCoach);
  byId("duration").addEventListener("input", updateCoach);
  setInterval(updateCoach, 1000);
  renderStep();
  updateCoach();
})();
