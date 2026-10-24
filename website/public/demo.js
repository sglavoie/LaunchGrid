// The home page's grid: type to search, ranked as the app ranks (Sources/LaunchGridCore/Search.swift).
const APPS = [
    ["Archive", "#ff9f0a"], ["Books", "#ff9f0a"], ["Calculator", "#8e8e93"], ["Calendar", "#ff375f"],
    ["Camera", "#40c8e0"], ["Chess", "#30d158"], ["Code Studio", "#0a84ff"], ["Contacts", "#ac8e68"],
    ["Disk Tools", "#8e8e93"], ["Draw", "#bf5af2"], ["Files", "#0a84ff"], ["Mail", "#40c8e0"],
    ["Maps", "#30d158"], ["Music", "#ff375f"], ["Notes", "#ffd60a"], ["Photos", "#ff9f0a"],
    ["Terminal", "#636366"], ["Video Stream Capture", "#5e5ce6"],
];

const normalize = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

function acronym(name) {
    let out = "", previous = " ";
    const isWord = (c) => /[\p{L}\p{N}]/u.test(c);
    for (const ch of name) {
        if (isWord(ch) && (!isWord(previous) || (ch !== ch.toLowerCase() && previous !== previous.toUpperCase()))) out += ch;
        previous = ch;
    }
    return normalize(out);
}

function isSubsequence(q, s) {
    let i = 0;
    for (const ch of q) {
        i = s.indexOf(ch, i);
        if (i < 0) return false;
        i += 1;
    }
    return true;
}

function score(name, query) {
    const q = normalize(query);
    if (!q) return null;
    const n = normalize(name);
    const len = Math.min(n.length, 99);
    if (n === q) return 1000;
    if (n.startsWith(q)) return 900 - len;
    const separators = /[^\p{L}\p{N}]+/u;
    const words = n.split(separators).filter(Boolean);
    if (words.some((w) => w.startsWith(q))) return 700 - len;
    // Several words, each starting a word of the name, in any order: "capture video".
    const queryWords = q.split(separators).filter(Boolean);
    if (queryWords.length > 1 && queryWords.every((qw) => words.some((w) => w.startsWith(qw)))) return 700 - len;
    if (acronym(name).startsWith(q)) return 600;
    if (n.includes(q)) return 500 - len;
    if (q.length >= 3 && isSubsequence(q, n)) return 200 - len;
    return null;
}

const input = document.getElementById("demo-search");
const list = document.getElementById("demo-tiles");
const note = document.getElementById("demo-note");
let shown = [];
let selected = -1;

function tile([name, color]) {
    const li = document.createElement("li");
    li.className = "tile";
    li.style.setProperty("--c", color);
    const glyph = document.createElement("span");
    glyph.className = "glyph";
    glyph.setAttribute("aria-hidden", "true");
    glyph.textContent = name.split(" ").map((w) => w[0]).join("").slice(0, 2);
    const label = document.createElement("span");
    label.className = "name";
    label.textContent = name;
    li.append(glyph, label);
    return li;
}

function render() {
    const q = input.value;
    shown = q.trim()
        ? APPS.map((a) => [a, score(a[0], q)]).filter(([, s]) => s !== null)
            .sort((a, b) => b[1] - a[1] || a[0][0].localeCompare(b[0][0])).map(([a]) => a)
        : APPS;
    selected = q.trim() && shown.length ? 0 : -1;
    list.replaceChildren(...shown.map(tile));
    paint();
    note.textContent = !q.trim() ? "" : shown.length
        ? `${shown.length} ${shown.length === 1 ? "match" : "matches"}. Return opens ${shown[0][0]}.`
        : "No apps match. Esc clears the search.";
}

function paint() {
    [...list.children].forEach((li, i) => li.classList.toggle("selected", i === selected));
}

function open() {
    const li = list.children[selected];
    if (!li) return;
    li.classList.remove("opening");
    void li.offsetWidth;
    li.classList.add("opening");
    note.textContent = `Opening ${shown[selected][0]}.`;
}

input.addEventListener("input", render);
input.addEventListener("keydown", (e) => {
    const cols = getComputedStyle(list).gridTemplateColumns.split(" ").length;
    const step = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: cols, ArrowUp: -cols }[e.key];
    if (step && shown.length && input.value.trim()) {
        e.preventDefault();
        selected = Math.min(shown.length - 1, Math.max(0, selected + step));
        paint();
        note.textContent = shown[selected][0];
    } else if (e.key === "Enter") {
        e.preventDefault();
        open();
    } else if (e.key === "Escape") {
        input.value = "";
        render();
    }
});

document.querySelectorAll("[data-try]").forEach((b) => b.addEventListener("click", () => {
    input.value = b.dataset.try;
    render();
    input.focus();
}));

render();

// A link to the section already in the address bar doesn't re-trigger :target, so replay its flash (style.css).
document.querySelectorAll('a[href^="/#"], a[href^="#"]').forEach((a) => a.addEventListener("click", () => {
    const hash = new URL(a.href).hash;
    if (hash !== location.hash) return;
    const section = document.querySelector(hash)?.closest(".section");
    if (!section) return;
    section.style.animation = "none";
    void section.offsetWidth;
    section.style.animation = "";
}));

// The video below the hero loops, with a button (or a click on the video) to pause it; with
// reduced motion, it waits for that button instead. Without this script it keeps native controls
// and its poster, and plays only when asked.
const video = document.getElementById("demo-video");
const toggle = document.getElementById("demo-video-toggle");
if (video && toggle) {
    const sync = () => {
        toggle.classList.toggle("paused", video.paused);
        toggle.setAttribute("aria-label", video.paused ? "Play the video" : "Pause the video");
    };
    // Set once the visitor pauses it, so scrolling it back into view doesn't restart it.
    let held = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const play = () => video.play().catch(() => {}); // a blocked play() leaves the play button showing
    const flip = () => {
        held = !video.paused;
        if (video.paused) play(); else video.pause();
    };
    video.controls = false;
    toggle.hidden = false;
    toggle.addEventListener("click", flip);
    video.addEventListener("click", flip);
    video.addEventListener("play", sync);
    video.addEventListener("pause", sync);
    sync();
    // Plays (and so downloads) only while in view: visitors who never scroll to it don't fetch it.
    if ("IntersectionObserver" in window) {
        new IntersectionObserver(([entry]) => {
            if (entry.isIntersecting && !held) play();
            else if (!entry.isIntersecting && !video.paused) video.pause();
        }, { threshold: 0.25 }).observe(video);
    } else if (!held) {
        play();
    }
}

// Settings screenshots: one panel at a time behind a tab list, arrow keys moving between tabs.
const settings = document.querySelector(".settings-tabs");
if (settings) {
    const tabs = [...settings.querySelectorAll('[role="tab"]')];
    const select = (tab, focus) => {
        for (const t of tabs) {
            const on = t === tab;
            t.setAttribute("aria-selected", String(on));
            t.tabIndex = on ? 0 : -1;
            const panel = document.getElementById(t.getAttribute("aria-controls"));
            panel.classList.toggle("current", on);
            panel.toggleAttribute("inert", !on);
        }
        if (focus) tab.focus();
    };
    tabs.forEach((tab, i) => {
        tab.addEventListener("click", () => select(tab, false));
        tab.addEventListener("keydown", (e) => {
            const step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
            const target = step ? tabs[(i + step + tabs.length) % tabs.length]
                : e.key === "Home" ? tabs[0] : e.key === "End" ? tabs.at(-1) : null;
            if (!target) return;
            e.preventDefault();
            select(target, true);
        });
    });
    settings.querySelector('[role="tablist"]').hidden = false;
    settings.classList.add("ready");
    select(tabs[0], false);
}
