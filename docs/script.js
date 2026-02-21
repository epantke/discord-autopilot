/* ── OS Detection & Download Button ──────────────────────────────────────── */
(function initDownloadButton() {
  const btn = document.getElementById("download-btn");
  if (!btn) return;

  const ua = navigator.userAgent.toLowerCase();
  const platform = navigator.platform?.toLowerCase() ?? "";

  let os = "other";
  if (platform.startsWith("win") || ua.includes("windows")) os = "windows";
  else if (platform.startsWith("mac") || ua.includes("macintosh")) os = "macos";
  else if (platform.startsWith("linux") || ua.includes("linux")) os = "linux";

  const base = "https://github.com/epantke/discord-autopilot/releases/latest/download/";

  if (os === "windows") {
    btn.href = base + "agent.ps1";
    btn.textContent = "↓ Download for Windows";
  } else if (os === "macos") {
    btn.href = base + "agent.sh";
    btn.textContent = "↓ Download for macOS";
  } else if (os === "linux") {
    btn.href = base + "agent.sh";
    btn.textContent = "↓ Download for Linux";
  } else {
    btn.href = "https://github.com/epantke/discord-autopilot/releases/latest";
    btn.textContent = "↓ Download";
  }
})();

/* ── Typing Animation ───────────────────────────────────────────────────── */
(function initTyping() {
  const el = document.getElementById("typed");
  if (!el) return;

  const phrases = [
    "refactor the auth module to use JWT",
    "add unit tests for the API endpoints",
    "fix the race condition in session handler",
    "migrate the database schema to v3",
    "optimize the query performance in search",
  ];

  let phraseIdx = 0;
  let charIdx = 0;
  let deleting = false;

  function tick() {
    const phrase = phrases[phraseIdx];

    if (!deleting) {
      charIdx++;
      el.textContent = phrase.slice(0, charIdx);
      if (charIdx === phrase.length) {
        deleting = true;
        setTimeout(tick, 2000);
        return;
      }
      setTimeout(tick, 45 + Math.random() * 35);
    } else {
      charIdx--;
      el.textContent = phrase.slice(0, charIdx);
      if (charIdx === 0) {
        deleting = false;
        phraseIdx = (phraseIdx + 1) % phrases.length;
        setTimeout(tick, 400);
        return;
      }
      setTimeout(tick, 25);
    }
  }

  setTimeout(tick, 800);
})();

/* ── Theme Toggle ───────────────────────────────────────────────────────── */
(function initTheme() {
  const toggle = document.getElementById("theme-toggle");
  if (!toggle) return;

  const stored = localStorage.getItem("theme");
  const prefersDark = matchMedia("(prefers-color-scheme: dark)").matches;
  const theme = stored || (prefersDark ? "dark" : "light");

  document.documentElement.setAttribute("data-theme", theme);
  toggle.textContent = theme === "dark" ? "🌙" : "☀️";

  toggle.addEventListener("click", () => {
    const current = document.documentElement.getAttribute("data-theme");
    const next = current === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    toggle.textContent = next === "dark" ? "🌙" : "☀️";
    localStorage.setItem("theme", next);
  });
})();

/* ── Sticky Nav Scroll Effect ───────────────────────────────────────────── */
(function initNavScroll() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  let ticking = false;
  window.addEventListener("scroll", () => {
    if (!ticking) {
      requestAnimationFrame(() => {
        nav.classList.toggle("scrolled", window.scrollY > 20);
        ticking = false;
      });
      ticking = true;
    }
  }, { passive: true });
})();

/* ── Mobile Hamburger Menu ──────────────────────────────────────────────── */
(function initHamburger() {
  const btn = document.getElementById("nav-hamburger");
  const links = document.getElementById("nav-links");
  if (!btn || !links) return;

  btn.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    btn.textContent = open ? "✕" : "☰";
    btn.setAttribute("aria-expanded", String(open));
  });

  // Close on link click
  links.querySelectorAll("a").forEach(a => {
    a.addEventListener("click", () => {
      links.classList.remove("open");
      btn.textContent = "☰";
      btn.setAttribute("aria-expanded", "false");
    });
  });
})();

/* ── Scroll Spy ─────────────────────────────────────────────────────────── */
(function initScrollSpy() {
  const sections = document.querySelectorAll("section[id]");
  const navLinks = document.querySelectorAll(".nav-links a[href^='#']");
  if (!sections.length || !navLinks.length) return;

  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const id = entry.target.getAttribute("id");
        navLinks.forEach(link => {
          link.classList.toggle("active", link.getAttribute("href") === "#" + id);
        });
      }
    });
  }, {
    rootMargin: "-20% 0px -70% 0px",
    threshold: 0,
  });

  sections.forEach(s => observer.observe(s));
})();

/* ── Reveal on Scroll ───────────────────────────────────────────────────── */
(function initReveal() {
  const els = document.querySelectorAll(".reveal");
  if (!els.length) return;

  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    });
  }, {
    threshold: 0.1,
    rootMargin: "0px 0px -40px 0px",
  });

  els.forEach(el => observer.observe(el));
})();

/* ── Copy Buttons ───────────────────────────────────────────────────────── */
(function initCopyButtons() {
  document.querySelectorAll(".copy-btn").forEach(btn => {
    btn.addEventListener("click", async () => {
      const pre = btn.closest(".code-block")?.querySelector("pre");
      if (!pre) return;

      try {
        await navigator.clipboard.writeText(pre.textContent);
        btn.textContent = "✓ Copied";
        btn.classList.add("copied");
        setTimeout(() => {
          btn.textContent = "📋 Copy";
          btn.classList.remove("copied");
        }, 2000);
      } catch {
        // Fallback: select text
        const range = document.createRange();
        range.selectNodeContents(pre);
        const sel = getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    });
  });
})();

/* ── Tabs (Quick Start) ─────────────────────────────────────────────────── */
(function initTabs() {
  const buttons = document.querySelectorAll(".tab-btn");
  const contents = document.querySelectorAll(".tab-content");
  if (!buttons.length) return;

  buttons.forEach(btn => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      buttons.forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
      contents.forEach(c => c.classList.toggle("active", c.dataset.tab === tab));
    });
  });
})();

/* ── Command Filter ─────────────────────────────────────────────────────── */
(function initCommandFilter() {
  const input = document.getElementById("cmd-filter");
  const table = document.getElementById("commands-table");
  if (!input || !table) return;

  const rows = Array.from(table.querySelectorAll("tbody tr"));

  input.addEventListener("input", () => {
    const q = input.value.toLowerCase().trim();
    rows.forEach(row => {
      const text = row.textContent.toLowerCase();
      row.style.display = text.includes(q) ? "" : "none";
    });
  });
})();

/* ── Scroll to Top ──────────────────────────────────────────────────────── */
(function initScrollTop() {
  const btn = document.getElementById("scroll-top");
  if (!btn) return;

  let ticking = false;
  window.addEventListener("scroll", () => {
    if (!ticking) {
      requestAnimationFrame(() => {
        btn.classList.toggle("visible", window.scrollY > 600);
        ticking = false;
      });
      ticking = true;
    }
  }, { passive: true });

  btn.addEventListener("click", () => {
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
})();
