"use strict";
// Authored synthetic UI only. No filesystem, network, or device data is read.
const tour = document.querySelector(".tour");
if (tour) {
  const screens = [...tour.querySelectorAll(".app-screen")];
  const tabs = [...tour.querySelectorAll(".screen-tab")];
  const play = document.querySelector("#tour-play");
  const stage = document.querySelector("#tour-stage");
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const copy = {
    checkup: ["A useful place to begin.", "Review the results of a checkup before choosing your next step."],
    cleanup: ["A fresh start for your workspace.", "Review development caches, see what’s selected, and choose what to keep."],
    ai: ["A little care for your AI tools.", "See caches, old versions and worktrees separately, with items held for review."],
    apps: ["See what comes with an app.", "Inspect an application and its related files together before uninstalling."],
    files: ["Follow the space.", "A bubble map turns disk usage into something you can explore."],
    activity: ["A clearer view of right now.", "CPU, memory, energy, disk, network and thermals, together in Activity."],
    storage: ["Put your storage in perspective.", "Understand where space goes with familiar categories and their contents."]
  };
  let index = 0, playing = !motion.matches, timer, expanded = false, inView = true;
  const scale = () => { if (!expanded) tour.style.setProperty("--tour-scale", stage.clientWidth / 1200); };
  const schedule = () => { clearTimeout(timer); if (playing && !document.hidden && !expanded && inView) timer = setTimeout(() => select((index + 1) % screens.length), 6000); };
  const sync = () => {
    tour.classList.toggle("is-playing", playing && !document.hidden && !expanded && inView);
    play.setAttribute("aria-label", playing ? "Pause tour" : "Play tour");
    play.innerHTML = playing ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5v14M15 5v14" /></svg>' : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m8 5 11 7-11 7z" /></svg>';
    schedule();
  };
  const select = (next, manual = false) => {
    if (manual) playing = false;
    const old = screens[index]; index = next;
    screens.forEach((screen, i) => { screen.classList.toggle("is-active", i === index); screen.classList.toggle("is-leaving", screen === old && i !== index); screen.setAttribute("aria-hidden", i !== index ? "true" : "false"); });
    tabs.forEach((tab, i) => { tab.setAttribute("aria-selected", String(i === index)); tab.tabIndex = i === index ? 0 : -1; });
    const text = copy[screens[index].dataset.screen];
    document.querySelector("#tour-title").textContent = text[0];
    document.querySelector("#tour-description").textContent = text[1];
    sync();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => select(i, true));
    tab.addEventListener("keydown", event => {
      let next;
      if (event.key === "ArrowRight") next = (i + 1) % tabs.length;
      if (event.key === "ArrowLeft") next = (i + tabs.length - 1) % tabs.length;
      if (event.key === "Home") next = 0;
      if (event.key === "End") next = tabs.length - 1;
      if (next !== undefined) { event.preventDefault(); select(next, true); tabs[next].focus(); }
    });
  });
  play.addEventListener("click", () => { playing = !playing; sync(); });
  motion.addEventListener("change", () => { if (motion.matches) { playing = false; sync(); } });
  document.addEventListener("visibilitychange", sync);
  const background = [...document.body.children].filter(el => el !== tour && !el.contains(tour));
  const mainSiblings = [...tour.parentElement.children].filter(el => el !== tour);
  const toggleExpanded = (open) => {
    expanded = open; playing = false;
    stage.tabIndex = open ? 0 : -1;
    stage.setAttribute("aria-label", "Scrollable Roomy interface preview");
    tour.classList.toggle("is-expanded", open);
    [...background, ...mainSiblings].forEach(el => { el.inert = open; });
    if (open) { tour.setAttribute("role", "dialog"); tour.setAttribute("aria-modal", "true"); tour.setAttribute("aria-label", "Roomy interface preview"); }
    else { tour.removeAttribute("role"); tour.removeAttribute("aria-modal"); tour.setAttribute("aria-label", "Animated Roomy interface tour"); }
    document.querySelector(".inspect-bar").hidden = !open;
    document.body.style.overflow = open ? "hidden" : "";
    if (open) document.querySelector("#tour-close").focus();
    else { scale(); document.querySelector("#tour-expand").focus(); }
    sync();
  };
  document.querySelector("#tour-expand").addEventListener("click", () => toggleExpanded(true));
  document.querySelector("#tour-close").addEventListener("click", () => toggleExpanded(false));
  document.addEventListener("keydown", event => {
    if (!expanded) return;
    if (event.key === "Escape") toggleExpanded(false);
    if (event.key === "Tab") {
      const items = [...tour.querySelectorAll("button, a[href], [tabindex]")].filter(el => el.tabIndex >= 0 && el.getClientRects().length);
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });
  new IntersectionObserver(entries => { inView = entries[0].isIntersecting; sync(); }, { threshold: 0.1 }).observe(stage);
  new ResizeObserver(scale).observe(stage);
  scale(); select(0);
}
