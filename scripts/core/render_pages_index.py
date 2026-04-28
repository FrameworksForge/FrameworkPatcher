#!/usr/bin/env python3
"""Render the GitHub Pages build index page.

The generated page is static and reads the JSON index files at runtime, so the
workflows only need to copy the resulting HTML into the gh-pages branch.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="dark light" />
  <title>__TITLE__</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #08111f;
      --bg-alt: #0d172a;
      --panel: rgba(12, 20, 36, 0.82);
      --panel-border: rgba(148, 163, 184, 0.18);
      --text: #e5eefc;
      --muted: #8ea0ba;
      --accent: #7dd3fc;
      --accent-strong: #38bdf8;
      --accent-soft: rgba(56, 189, 248, 0.16);
      --danger: #fb7185;
      --shadow: 0 24px 80px rgba(2, 6, 23, 0.45);
      --radius: 22px;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      background:
        radial-gradient(circle at top left, rgba(56, 189, 248, 0.18), transparent 34%),
        radial-gradient(circle at top right, rgba(125, 211, 252, 0.12), transparent 28%),
        linear-gradient(180deg, #050b14 0%, var(--bg) 30%, #091120 100%);
      color: var(--text);
      font: 15px/1.6 Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .shell {
      width: min(1180px, calc(100% - 32px));
      margin: 0 auto;
      padding: 32px 0 56px;
    }

    .hero {
      position: relative;
      overflow: hidden;
      padding: 32px;
      border: 1px solid var(--panel-border);
      border-radius: 30px;
      background: linear-gradient(180deg, rgba(12, 20, 36, 0.9), rgba(8, 17, 31, 0.86));
      box-shadow: var(--shadow);
      backdrop-filter: blur(20px);
    }

    .hero::after {
      content: "";
      position: absolute;
      inset: auto -8% -50% auto;
      width: 320px;
      height: 320px;
      border-radius: 999px;
      background: radial-gradient(circle, rgba(56, 189, 248, 0.16), transparent 72%);
      pointer-events: none;
    }

    .eyebrow {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 12px;
      border: 1px solid rgba(125, 211, 252, 0.24);
      border-radius: 999px;
      background: rgba(14, 24, 41, 0.72);
      color: var(--accent);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.12em;
      text-transform: uppercase;
    }

    h1 {
      margin: 18px 0 10px;
      font-size: clamp(2.3rem, 5vw, 4.4rem);
      line-height: 0.95;
      letter-spacing: -0.05em;
      max-width: 12ch;
    }

    .lede {
      max-width: 72ch;
      margin: 0;
      color: var(--muted);
      font-size: 1.02rem;
    }

    .hero-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 14px;
      margin-top: 26px;
    }

    .stat {
      padding: 16px 18px;
      border: 1px solid var(--panel-border);
      border-radius: 18px;
      background: rgba(10, 16, 31, 0.72);
    }

    .stat-label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.12em;
    }

    .stat-value {
      margin-top: 6px;
      font-size: 1.5rem;
      font-weight: 700;
    }

    .section {
      margin-top: 22px;
      padding: 22px;
      border: 1px solid var(--panel-border);
      border-radius: var(--radius);
      background: var(--panel);
      box-shadow: var(--shadow);
      backdrop-filter: blur(18px);
    }

    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 18px;
    }

    .toolbar h2 {
      margin: 0;
      font-size: 1.2rem;
    }

    .search {
      flex: 1 1 320px;
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: min(100%, 320px);
      padding: 14px 16px;
      border: 1px solid rgba(148, 163, 184, 0.18);
      border-radius: 16px;
      background: rgba(4, 8, 16, 0.48);
    }

    .search svg {
      flex: 0 0 auto;
      color: var(--muted);
    }

    .search input {
      width: 100%;
      border: 0;
      outline: 0;
      background: transparent;
      color: var(--text);
      font: inherit;
    }

    .search input::placeholder {
      color: #6f829d;
    }

    .status {
      margin: 0 0 18px;
      color: var(--muted);
    }

    .latest {
      margin-bottom: 18px;
      padding: 18px;
      border: 1px solid rgba(125, 211, 252, 0.22);
      border-radius: 18px;
      background: linear-gradient(135deg, rgba(8, 18, 35, 0.95), rgba(14, 24, 41, 0.72));
    }

    .latest-title {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 12px;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }

    .build-list {
      display: grid;
      gap: 14px;
    }

    .build-card {
      padding: 18px;
      border: 1px solid rgba(148, 163, 184, 0.16);
      border-radius: 18px;
      background: rgba(9, 15, 27, 0.76);
    }

    .build-card header {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      justify-content: space-between;
      align-items: flex-start;
    }

    .build-title {
      margin: 0;
      font-size: 1.05rem;
    }

    .build-meta {
      margin-top: 6px;
      color: var(--muted);
      font-size: 0.95rem;
    }

    .build-pill-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 12px;
    }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px 10px;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.18);
      background: rgba(2, 6, 23, 0.38);
      color: var(--text);
      font-size: 12px;
    }

    .pill strong {
      color: var(--accent);
      font-weight: 700;
    }

    .mono {
      font-family: ui-monospace, SFMono-Regular, SF Mono, Consolas, "Liberation Mono", Menlo, monospace;
    }

    .build-link {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 12px;
      background: linear-gradient(135deg, var(--accent-strong), #0ea5e9);
      color: #00111f;
      font-weight: 700;
      text-decoration: none;
      white-space: nowrap;
      box-shadow: 0 10px 24px rgba(14, 165, 233, 0.24);
    }

    .build-link:hover,
    .build-link:focus-visible {
      filter: brightness(1.05);
      transform: translateY(-1px);
    }

    .empty {
      padding: 28px 18px;
      border: 1px dashed rgba(148, 163, 184, 0.24);
      border-radius: 18px;
      color: var(--muted);
      text-align: center;
    }

    .footer {
      margin-top: 18px;
      color: var(--muted);
      font-size: 0.9rem;
      text-align: center;
    }

    .hidden {
      display: none !important;
    }

    @media (max-width: 860px) {
      .hero-grid {
        grid-template-columns: 1fr;
      }

      .hero,
      .section {
        padding: 20px;
      }
    }
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero">
      <span class="eyebrow">GitHub Pages build index</span>
      <h1>FrameworkPatcher builds</h1>
      <p class="lede">
        Search the published builds below. Each entry includes the device, ROM target, build metadata,
        and a direct release link when one exists.
      </p>
      <div class="hero-grid" id="hero-stats">
        <div class="stat">
          <div class="stat-label">Published builds</div>
          <div class="stat-value" id="build-count">0</div>
        </div>
        <div class="stat">
          <div class="stat-label">Devices tracked</div>
          <div class="stat-value" id="device-count">0</div>
        </div>
        <div class="stat">
          <div class="stat-label">Last updated</div>
          <div class="stat-value mono" id="updated-at">Loading</div>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="toolbar">
        <h2>Builds</h2>
        <label class="search" aria-label="Search builds">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
            <path d="M21 21l-4.2-4.2m1.7-5.1a7.8 7.8 0 11-15.6 0 7.8 7.8 0 0115.6 0z" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
          <input id="search" type="search" placeholder="Search device, ROM, Android version, patch version, feature..." autocomplete="off" />
        </label>
      </div>

      <div class="latest hidden" id="latest-panel">
        <div class="latest-title">
          <div>
            <span class="badge">Latest stable</span>
            <h3 id="latest-title" style="margin: 10px 0 0;">Loading latest release</h3>
          </div>
          <a class="build-link" id="latest-link" href="#" rel="noreferrer">Open release</a>
        </div>
        <div class="build-meta" id="latest-meta"></div>
      </div>

      <p class="status" id="status">Loading build index...</p>
      <div class="build-list" id="build-list"></div>
      <div class="empty hidden" id="empty-state">No builds match your search.</div>
      <div class="footer">Generated in $YEAR for the FrameworkPatcher GitHub Pages branch.</div>
    </section>
  </main>

  <script>
    const state = {
      builds: [],
      latest: null,
      query: "",
    };

    const searchInput = document.getElementById("search");
    const buildList = document.getElementById("build-list");
    const emptyState = document.getElementById("empty-state");
    const status = document.getElementById("status");
    const buildCount = document.getElementById("build-count");
    const deviceCount = document.getElementById("device-count");
    const updatedAt = document.getElementById("updated-at");
    const latestPanel = document.getElementById("latest-panel");
    const latestTitle = document.getElementById("latest-title");
    const latestMeta = document.getElementById("latest-meta");
    const latestLink = document.getElementById("latest-link");

    function escapeHtml(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function formatDate(value) {
      if (!value) {
        return "Unknown";
      }

      const parsed = new Date(value);
      if (Number.isNaN(parsed.getTime())) {
        return value;
      }

      return parsed.toLocaleString(undefined, {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        timeZoneName: "short",
      });
    }

    function flattenBuilds(indexData) {
      const devices = indexData?.devices ?? {};
      const flattened = [];

      for (const [device, baseRomMap] of Object.entries(devices)) {
        for (const [baseRom, entry] of Object.entries(baseRomMap ?? {})) {
          flattened.push({
            device,
            base_rom: baseRom,
            ...entry,
          });
        }
      }

      flattened.sort((left, right) => String(right.build_time || "").localeCompare(String(left.build_time || "")));
      return flattened;
    }

    function buildSearchText(entry) {
      return [
        entry.device,
        entry.base_rom,
        entry.android_version,
        entry.patch_version,
        entry.build_time,
        entry.release_url,
        (entry.features || []).join(" "),
      ].join(" ").toLowerCase();
    }

    function renderLatest() {
      if (!state.latest) {
        latestPanel.classList.add("hidden");
        return;
      }

      latestPanel.classList.remove("hidden");
      latestTitle.textContent = `Framework Engine v${state.latest.engine_version || "unknown"}`;
      latestMeta.textContent = `Released ${formatDate(state.latest.release_date)} • Supports Android ${Array.isArray(state.latest.supported_android) ? state.latest.supported_android.join(", ") : "unknown"}`;
      latestLink.href = state.latest.release_url || "#";
    }

    function renderBuilds() {
      const query = state.query.trim().toLowerCase();
      const filtered = state.builds.filter((entry) => !query || buildSearchText(entry).includes(query));

      buildCount.textContent = String(state.builds.length);
      deviceCount.textContent = String(new Set(state.builds.map((entry) => entry.device)).size);
      updatedAt.textContent = formatDate(state.builds[0]?.build_time || state.latest?.release_date || "");
      status.textContent = filtered.length
        ? `Showing ${filtered.length} of ${state.builds.length} build${state.builds.length === 1 ? "" : "s"}`
        : state.builds.length
          ? "No builds match the current search."
          : "No build entries are published yet.";

      buildList.innerHTML = filtered.length
        ? filtered.map((entry) => {
            const releaseUrl = entry.release_url || entry.workflow_url || "#";
            const features = Array.isArray(entry.features) && entry.features.length
              ? entry.features
              : [];

            return `
              <article class="build-card" data-search="${escapeHtml(buildSearchText(entry))}">
                <header>
                  <div>
                    <h3 class="build-title">${escapeHtml(entry.device)} · ${escapeHtml(entry.base_rom)}</h3>
                    <div class="build-meta">Android ${escapeHtml(entry.android_version || "unknown")} · Patch ${escapeHtml(entry.patch_version || "unknown")} · Built ${escapeHtml(formatDate(entry.build_time))}</div>
                  </div>
                  <a class="build-link" href="${escapeHtml(releaseUrl)}" target="_blank" rel="noreferrer">Open release</a>
                </header>

                <div class="build-pill-row">
                  <span class="pill"><strong>Release</strong> <span class="mono">${escapeHtml(releaseUrl)}</span></span>
                  <span class="pill"><strong>Workflow</strong> <span class="mono">${escapeHtml(entry.workflow_url || "n/a")}</span></span>
                  <span class="pill"><strong>Run</strong> <span class="mono">${escapeHtml(entry.workflow_run_id || "n/a")}</span></span>
                  ${features.map((feature) => `<span class="pill">${escapeHtml(feature)}</span>`).join("")}
                </div>
              </article>
            `;
          }).join("")
        : "";

      if (filtered.length) {
        emptyState.classList.add("hidden");
      } else {
        emptyState.textContent = state.builds.length ? "No builds match your search." : "No build entries are published yet.";
        emptyState.classList.remove("hidden");
      }
    }

    async function loadJson(path) {
      try {
        const response = await fetch(path, { cache: "no-store" });
        if (!response.ok) {
          return null;
        }

        return await response.json();
      } catch (error) {
        return null;
      }
    }

    async function bootstrap() {
      const [indexData, latestData] = await Promise.all([
        loadJson("builds/index.json"),
        loadJson("builds/latest.json"),
      ]);

      state.builds = flattenBuilds(indexData);
      state.latest = latestData;

      if (indexData?.last_updated) {
        updatedAt.textContent = formatDate(indexData.last_updated);
      }

      renderLatest();
      renderBuilds();

      if (state.builds.length) {
        status.textContent = `Showing ${state.builds.length} published build${state.builds.length === 1 ? "" : "s"}`;
      } else if (!state.latest) {
        status.textContent = "No builds or releases have been published yet.";
      } else {
        status.textContent = "Release metadata is available, but no build history has been indexed yet.";
      }
    }

    searchInput.addEventListener("input", (event) => {
      state.query = event.target.value;
      renderBuilds();
    });

    bootstrap();
  </script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Render the FrameworkPatcher GitHub Pages index.")
    parser.add_argument("--output", default="-", help="Write the HTML to this path, or '-' for stdout.")
    parser.add_argument("--title", default="FrameworkPatcher Builds", help="Page title.")
    args = parser.parse_args()

    page = HTML_TEMPLATE.replace("__TITLE__", args.title).replace("$YEAR", str(datetime.now(timezone.utc).year))

    if args.output == "-":
        print(page)
        return 0

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(page, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())