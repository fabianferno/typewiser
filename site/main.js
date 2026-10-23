// Hero demo: types a raw transcript while the HUD listens, then "pastes" the cleanup.
const demos = [
  {
    app: "Slack · #product",
    raw: [["um ", 1], ["so ", 1], ["hey team I just finished reviewing the the onboarding flow and ", 0], ["uh ", 1], ["I think we should ship it on Thursday", 0]],
    clean: "Hey team, I just finished reviewing the onboarding flow and I think we should ship it on Thursday.",
    hint: "hold",
  },
  {
    app: "Mail · Re: Offsite",
    raw: [["let's do the offsite on the 12th ", 0], ["no wait actually ", 1], ["the 19th, and can you book the room for ", 0], ["like ", 1], ["twenty people", 0]],
    clean: "Let's do the offsite on the 19th. Can you book the room for 20 people?",
    hint: "hold",
  },
  {
    app: "Notes · Weekly update",
    raw: [["okay so three things this week ", 0], ["um ", 1], ["first the billing migration is done second we hired a designer and third ", 0], ["you know ", 1], ["the iOS beta goes out Monday", 0]],
    clean: "Three things this week:\n1. The billing migration is done.\n2. We hired a designer.\n3. The iOS beta goes out Monday.",
    hint: "double-tap",
  },
];

const $ = (id) => document.getElementById(id);
const rawEl = $("demo-raw"), cleanEl = $("demo-clean"), appEl = $("demo-app");
const hud = $("hud"), hudLabel = $("hud-label"), keycap = $("keycap"), keyhint = $("keyhint");
const tabs = [...document.querySelectorAll(".tabs [data-demo]")];
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

let run = 0;
let current = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function play(i) {
  const id = ++run;
  const alive = () => id === run;
  const d = demos[i];
  current = i;
  tabs.forEach((t, n) => t.setAttribute("aria-selected", String(n === i)));
  appEl.textContent = d.app;
  rawEl.textContent = "";
  cleanEl.innerHTML = '<span class="caret"></span>';

  if (reduced) {
    rawEl.innerHTML = d.raw.map(([t, f]) => (f ? `<span class="filler">${t}</span>` : t)).join("");
    cleanEl.textContent = d.clean;
    return;
  }

  // Press the key
  if (d.hint === "double-tap") {
    keyhint.textContent = "double-tap";
    for (let n = 0; n < 2; n++) {
      keycap.classList.add("down"); await sleep(120);
      keycap.classList.remove("down"); await sleep(140);
    }
    keyhint.textContent = "🔒 latched";
  } else {
    keyhint.textContent = "holding…";
    keycap.classList.add("down");
  }
  hud.classList.remove("working");
  hudLabel.textContent = "Listening";
  hud.classList.add("on");
  await sleep(400);

  // Speak: type the raw transcript word by word
  for (const [text, filler] of d.raw) {
    const span = document.createElement("span");
    if (filler) span.className = "filler";
    rawEl.appendChild(span);
    for (const word of text.split(/(?<= )/)) {
      if (!alive()) return;
      span.textContent += word;
      await sleep(85 + Math.random() * 70);
    }
  }
  await sleep(300);

  // Release
  if (d.hint === "double-tap") {
    keycap.classList.add("down"); await sleep(120); keycap.classList.remove("down");
    keyhint.textContent = "tap to stop";
  } else {
    keycap.classList.remove("down");
    keyhint.textContent = "released";
  }
  hud.classList.add("working");
  hudLabel.textContent = "Cleaning up";
  await sleep(900);
  if (!alive()) return;
  hud.classList.remove("on");

  // Paste
  cleanEl.textContent = d.clean;
  keyhint.textContent = "pasted ✓";
  await sleep(3200);
  if (!alive()) return;
  keyhint.textContent = d.hint === "double-tap" ? "double-tap" : "hold";
  play((current + 1) % demos.length);
}

tabs.forEach((t, n) => t.addEventListener("click", () => {
  keycap.classList.remove("down");
  play(n);
}));

// Start when the panel scrolls into view
const sky = document.querySelector(".sky");
const io = new IntersectionObserver((entries) => {
  if (entries.some((e) => e.isIntersecting)) { io.disconnect(); play(0); }
}, { threshold: 0.25 });
io.observe(sky);

// Engine segmented control
document.querySelectorAll(".seg [data-seg]").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".seg [data-seg]").forEach((b) => b.setAttribute("aria-selected", String(b === btn)));
    document.querySelectorAll("[data-list]").forEach((l) => { l.hidden = l.dataset.list !== btn.dataset.seg; });
  });
});

// Copy build commands
document.querySelector(".copy")?.addEventListener("click", async (e) => {
  const text = document.querySelector(".code code").innerText.split("\n").filter((l) => !l.startsWith("#")).join("\n");
  try {
    await navigator.clipboard.writeText(text);
    e.target.textContent = "Copied";
  } catch {
    e.target.textContent = "Select to copy";
  }
  setTimeout(() => { e.target.textContent = "Copy"; }, 1600);
});

// Keycap buttons: press state + synthesized key click
const keys = document.querySelectorAll(".btn, .tabs button, .seg button, .copy");
let actx;
function keySound(down) {
  try {
    actx ||= new (window.AudioContext || window.webkitAudioContext)();
    if (actx.state === "suspended") actx.resume();
    const t = actx.currentTime, vol = down ? 0.5 : 0.28;
    // noisy transient, band-passed so it reads as plastic
    const len = Math.floor(actx.sampleRate * 0.035);
    const buf = actx.createBuffer(1, len, actx.sampleRate), ch = buf.getChannelData(0);
    for (let i = 0; i < len; i++) ch[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
    const noise = actx.createBufferSource(); noise.buffer = buf;
    const bp = actx.createBiquadFilter(); bp.type = "bandpass"; bp.frequency.value = down ? 2400 : 3400; bp.Q.value = 0.9;
    const ng = actx.createGain(); ng.gain.value = vol;
    noise.connect(bp).connect(ng).connect(actx.destination); noise.start(t);
    // low body thock
    const o = actx.createOscillator(), og = actx.createGain();
    o.type = "sine"; o.frequency.setValueAtTime(down ? 210 : 280, t); o.frequency.exponentialRampToValueAtTime(90, t + 0.05);
    og.gain.setValueAtTime(down ? 0.35 : 0.15, t); og.gain.exponentialRampToValueAtTime(0.001, t + 0.06);
    o.connect(og).connect(actx.destination); o.start(t); o.stop(t + 0.07);
  } catch {}
}
keys.forEach((k) => {
  const down = () => { k.classList.add("is-down"); keySound(true); };
  const up = (snd) => { if (k.classList.contains("is-down")) { k.classList.remove("is-down"); if (snd) keySound(false); } };
  k.addEventListener("pointerdown", (e) => { if (e.button === 0) down(); });
  k.addEventListener("pointerup", () => up(true));
  k.addEventListener("pointerleave", () => up(false));
  k.addEventListener("pointercancel", () => up(false));
  k.addEventListener("keydown", (e) => { if ((e.key === "Enter" || e.key === " ") && !e.repeat) down(); });
  k.addEventListener("keyup", () => up(true));
  k.addEventListener("blur", () => up(false));
});

// Floating icons in the sky panel: drag them anywhere inside the panel
document.querySelectorAll(".floaters .fl").forEach((el) => {
  const sky = el.closest(".sky");
  let sx = 0, sy = 0, ox = 0, oy = 0, minX = 0, maxX = 0, minY = 0, maxY = 0;
  const cur = () => [parseFloat(el.style.getPropertyValue("--dx")) || 0, parseFloat(el.style.getPropertyValue("--dy")) || 0];
  el.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    el.setPointerCapture(e.pointerId);
    [ox, oy] = cur(); sx = e.clientX; sy = e.clientY;
    const s = sky.getBoundingClientRect(), r = el.getBoundingClientRect();
    minX = ox + (s.left - r.left); maxX = ox + (s.right - r.right);
    minY = oy + (s.top - r.top); maxY = oy + (s.bottom - r.bottom);
    el.classList.add("dragging");
  });
  el.addEventListener("pointermove", (e) => {
    if (!el.classList.contains("dragging")) return;
    const x = Math.min(maxX, Math.max(minX, ox + e.clientX - sx));
    const y = Math.min(maxY, Math.max(minY, oy + e.clientY - sy));
    el.style.setProperty("--dx", x + "px"); el.style.setProperty("--dy", y + "px");
  });
  const end = () => el.classList.remove("dragging");
  el.addEventListener("pointerup", end);
  el.addEventListener("pointercancel", end);
});
