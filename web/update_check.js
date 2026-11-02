(() => {
  "use strict";
  const CHECK_MS = 15_000, FRESH_MS = 75_000;
  const ATTEMPT_KEY = "uten-web-update-attempt", RELEASE_PARAM = "uten-web-release";
  const VERSION_RE = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
  const baseline = document.querySelector('meta[name="uten-release-version"]')?.getAttribute("content")?.trim();
  const stamped = typeof baseline === "string" && VERSION_RE.test(baseline);
  let target, metadataFlight, surface, message, version, brandParts, previousFocus;
  let busy = false, navigating = false, maintenanceSeen = false, recoveryKey = "", generation = 0, waitingForWork = false;
  const inertChildren = new Map();
  const token = (value) => value.version + ":" + value.commitSha;
  function valid(value) {
    return value && typeof value === "object" && !Array.isArray(value)
      && Object.keys(value).sort().join(",") === "commitSha,product,releaseSequence,schemaVersion,version"
      && value.schemaVersion === 1 && value.product === "uten-imp"
      && typeof value.version === "string" && VERSION_RE.test(value.version)
      && Number.isSafeInteger(value.releaseSequence) && value.releaseSequence > 0
      && typeof value.commitSha === "string" && /^[0-9a-f]{40}$/.test(value.commitSha);
  }
  async function json(url) {
    const controller = new AbortController();
    let timer;
    try {
      return await Promise.race([
        fetch(url, { cache: "no-store", credentials: "same-origin", redirect: "error",
          headers: { Accept: "application/json", "Cache-Control": "no-cache" }, signal: controller.signal })
          .then((response) => response.ok ? response.json() : null),
        new Promise((resolve) => { timer = window.setTimeout(() => { controller.abort(); resolve(null); }, 4_000); }),
      ]);
    } catch { return null; }
    finally { window.clearTimeout(timer); }
  }
  function metadata() {
    if (!metadataFlight) {
      const url = new URL("version.json", document.baseURI);
      url.searchParams.set("uten-update-check", Date.now().toString());
      metadataFlight = json(url).then((value) => valid(value) ? value : null)
        .finally(() => { metadataFlight = undefined; });
    }
    return metadataFlight;
  }
  function maintenance() {
    const value = window.utenWebServerMaintenance;
    if (!value || value.schemaVersion !== 1 || !["available", "scheduled", "updating", "recovery_required"].includes(value.state)
      || !Number.isFinite(value.updatedAt) || value.updatedAt > Date.now() + 1_000
      || Date.now() - value.updatedAt > FRESH_MS) return null;
    return value;
  }
  const blocks = (state) => state?.state === "updating" || state?.state === "recovery_required";
  function canResume() {
    const state = maintenance();
    return document.visibilityState !== "hidden" && state !== null && !blocks(state)
      && (!maintenanceSeen || state?.state === "available");
  }
  async function prepare() {
    let timer;
    try {
      return await Promise.race([window.utenWebUpdatePrepare(), new Promise((resolve) => {
        timer = window.setTimeout(() => resolve(false), 8_000);
      })]);
    } finally { window.clearTimeout(timer); }
  }
  function branding() {
    if (!brandParts) return;
    const value = window.utenWebUpdateBranding;
    const text = (name, fallback) => typeof name === "string" && name.trim() && name.length <= 160
      && !/[\u0000-\u001f\u007f]/.test(name) ? name.trim() : fallback;
    brandParts.company.textContent = text(value?.companyName, "中山市优腾电器有限公司");
    brandParts.platform.textContent = text(value?.platformName, "优腾综合管理平台");
  }
  function show() {
    if (surface) return;
    previousFocus = document.activeElement;
    surface = document.createElement("div"); surface.id = "uten-web-update-status";
    surface.setAttribute("role", "dialog"); surface.setAttribute("aria-modal", "true");
    surface.setAttribute("aria-labelledby", "uten-web-update-title"); surface.setAttribute("tabindex", "-1");
    const card = document.createElement("section"); card.className = "uten-web-update-card";
    const brand = document.createElement("header"); brand.className = "uten-web-update-brand";
    const company = document.createElement("strong"), platform = document.createElement("span");
    brandParts = { company, platform }; branding(); brand.append(company, platform);
    const title = document.createElement("h1"); title.id = "uten-web-update-title"; title.textContent = "服务器正在更新中";
    message = document.createElement("p"); message.id = "uten-web-update-message";
    message.setAttribute("role", "status"); message.setAttribute("aria-live", "polite");
    version = document.createElement("p"); version.className = "uten-web-update-version";
    const hint = document.createElement("p"); hint.className = "uten-web-update-hint";
    hint.textContent = "请保留此窗口，更新完成后会自动刷新并进入最新版本。";
    card.append(brand, title, message, version, hint); surface.append(card);
    for (const child of document.body.children) { inertChildren.set(child, child.inert); child.inert = true; }
    document.body.append(surface); surface.focus({ preventScroll: true });
  }
  function resumeWork() {
    // An uncheckpointed editor or ambiguous submission must remain reachable.
    // This is a status banner; no manual-update decision is requested.
    waitingForWork = true;
    surface.className = "uten-web-update-waiting";
    surface.setAttribute("role", "status"); surface.setAttribute("aria-modal", "false");
    for (const [child, inert] of inertChildren) child.inert = inert;
    inertChildren.clear();
    if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
    previousFocus = undefined;
  }
  function hide() {
    surface?.remove(); surface = message = version = brandParts = undefined;
    for (const [child, inert] of inertChildren) child.inert = inert;
    inertChildren.clear();
    if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
    previousFocus = undefined; waitingForWork = false;
  }
  function status(text) {
    show(); message.textContent = text;
    version.textContent = target ? "正在同步版本 " + target.version : "";
  }
  function attempt(value, recovery = "") { return token(value) + (recovery ? "|" + recovery : ""); }
  function attempted(value, recovery) {
    const key = attempt(value, recovery), url = new URL(window.location.href);
    if (url.searchParams.get(RELEASE_PARAM) === key) return true;
    try { return window.sessionStorage.getItem(ATTEMPT_KEY) === key; } catch { return false; }
  }
  function navigate(value, recovery = "", authorized = false) {
    if (navigating || attempted(value, recovery)) return false;
    const key = attempt(value, recovery), url = new URL(window.location.href);
    url.searchParams.set(RELEASE_PARAM, key);
    try { window.sessionStorage.setItem(ATTEMPT_KEY, key); } catch { /* The URL also bounds retries. */ }
    window.utenWebServerReloadAuthorized = authorized;
    navigating = true;
    window.location.replace(url.toString());
    return true;
  }
  async function check() {
    if (!stamped || navigating || busy || document.visibilityState === "hidden") return;
    const state = maintenance();
    if (!state || blocks(state)) return;
    // Never release an observed maintenance page on an absent/stale projection.
    if (maintenanceSeen && state?.state !== "available") return;
    busy = true;
    const observed = generation;
    try {
      const latest = await metadata();
      if (observed !== generation || !canResume()) return;
      if (!latest) { if (surface) status("暂时无法确认最新版本，正在自动重试。"); return; }
      target = latest;
      if (latest.version === baseline && !maintenanceSeen) { hide(); return; }
      if (!waitingForWork) status("正在检查服务恢复状态…");
      const health = await json(new URL("/actuator/health/readiness", document.baseURI));
      if (observed !== generation || !canResume()) return;
      if (health?.status !== "UP") { status("正在等待服务器完成更新和运行检查…"); return; }
      if (typeof window.utenWebUpdatePrepare !== "function") {
        status("正在等待页面完成初始化…"); return;
      }
      if (!waitingForWork) status("正在保存本机草稿并准备最新页面…");
      const prepared = await prepare();
      if (observed !== generation || !canResume()) return;
      // Probe again after storage/network waits, immediately before navigation.
      const safety = window.utenWebUpdateSafetyProbe?.();
      if (prepared !== true || safety?.schemaVersion !== 1 || safety.ready !== true
        || safety.serverReloadSafe !== true || safety.busy !== false
        || !Number.isFinite(safety.updatedAt) || Date.now() - safety.updatedAt > 25_000
        || safety.updatedAt > Date.now() + 1_000) {
        status("服务已恢复，请完成当前操作。完成后页面会自动更新。"); resumeWork(); return;
      }
      status("服务已恢复，正在进入最新版本…");
      if (!navigate(latest, maintenanceSeen ? recoveryKey : "", true)) {
        status("正在等待浏览器获取最新页面，请保持网络连接。");
      }
    } catch { status("正在准备最新页面，稍后会自动重试。"); }
    finally { busy = false; }
  }
  function serverChanged() {
    const state = maintenance();
    if (!state) return;
    generation++;
    if (blocks(state)) {
      if (waitingForWork) hide();
      maintenanceSeen = true;
      recoveryKey = typeof state.noticeKey === "string" ? state.noticeKey : "maintenance";
      status(state.state === "recovery_required"
        ? "更新尚未完成，正在等待管理员恢复服务。"
        : "正在更新服务并检查运行状态…");
    } else { void check(); }
  }
  // A fresh entry has no mounted editor or credentials in flight yet.
  window.utenWebUpdateGate = (async () => {
    if (!stamped) return { navigating: false };
    const value = await metadata();
    if (value && value.version !== baseline && navigate(value)) return { navigating: true };
    return { navigating: false };
  })();
  if (!stamped) return;
  window.setInterval(() => { void check(); }, CHECK_MS);
  window.addEventListener("online", () => { void check(); });
  window.addEventListener("uten:web-server-maintenance", serverChanged);
  window.addEventListener("uten:web-update-branding", branding);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") { serverChanged(); void check(); }
  });
  serverChanged();
})();
