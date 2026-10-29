(() => {
  "use strict";
  const CHECK_MS = 60_000, IDLE_MS = 60_000, COUNTDOWN_MS = 10_000, FRESH_MS = 25_000;
  const DIALOG_ID = "uten-web-update-dialog", ATTEMPT_KEY = "uten-web-update-attempt", RELEASE_PARAM = "uten-web-release";
  const AUTO_IDLE_KEY = "uten.webUpdate.autoWhenIdle";
  const VERSION_RE = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
  const COMMIT_RE = /^[0-9a-f]{40}$/;
  const DEFAULT_BRANDING = {
    schemaVersion: 1, companyName: "中山市优腾电器有限公司", platformName: "优腾综合管理平台",
  };
  const baseline = document.querySelector('meta[name="uten-release-version"]')?.getAttribute("content")?.trim();
  const stamped = typeof baseline === "string" && VERSION_RE.test(baseline);
  let target, fetchInFlight, deadline, modal, message, latestVersion, autoChoice, primary, secondary, previousFocus, deferredUnsafe, transientMessage, countdownRow, countdownValue;
  let refreshing = false, navigating = false, lastActivity = Date.now(), retryAfter = 0;
  let autoWhenIdle = true;
  try { autoWhenIdle = window.localStorage.getItem(AUTO_IDLE_KEY) !== "false"; } catch { /* The in-memory choice remains usable. */ }
  let brandParts, brandSignature;
  const token = (value) => value.version + ":" + value.commitSha;
  function valid(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    if (Object.keys(value).sort().join(",") !== "commitSha,product,releaseSequence,schemaVersion,version") return false;
    return value.schemaVersion === 1 && value.product === "uten-imp"
      && typeof value.version === "string" && VERSION_RE.test(value.version)
      && Number.isSafeInteger(value.releaseSequence) && value.releaseSequence > 0
      && typeof value.commitSha === "string" && COMMIT_RE.test(value.commitSha);
  }
  function metadata() {
    if (fetchInFlight) return fetchInFlight;
    fetchInFlight = (async () => {
      let timer;
      const controller = typeof AbortController === "function" ? new AbortController() : null;
      try {
        const url = new URL("version.json", document.baseURI);
        url.searchParams.set("uten-update-check", Date.now().toString());
        const request = fetch(url, {
          cache: "no-store", credentials: "same-origin",
          headers: { Accept: "application/json", "Cache-Control": "no-cache" },
          ...(controller ? { signal: controller.signal } : {}),
        }).then(async (response) => {
          if (!response.ok) return null;
          const value = await response.json();
          return valid(value) ? value : null;
        });
        return await Promise.race([request, new Promise((resolve) => {
          timer = window.setTimeout(() => { controller?.abort(); resolve(null); }, 4_000);
        })]);
      } catch { return null; }
      finally { if (timer !== undefined) window.clearTimeout(timer); }
    })().finally(() => { fetchInFlight = undefined; });
    return fetchInFlight;
  }
  function attempted(value) {
    if (new URL(window.location.href).searchParams.get(RELEASE_PARAM) === token(value)) return true;
    try { return window.sessionStorage.getItem(ATTEMPT_KEY) === token(value); } catch { return false; }
  }
  function navigate(value, manual = false) {
    if (navigating || (!manual && attempted(value))) return false;
    const url = new URL(window.location.href);
    url.searchParams.set(RELEASE_PARAM, token(value));
    // A URL marker still bounds retries when session storage is unavailable.
    try { window.sessionStorage.setItem(ATTEMPT_KEY, token(value)); } catch { /* URL marker remains. */ }
    navigating = true;
    window.location.replace(url.toString());
    return true;
  }
  function safety(probe = false) {
    if (typeof window.utenWebUpdateSafetyProbe !== "function") return null;
    let value = window.utenWebUpdateSafety;
    if (probe) {
      try { value = window.utenWebUpdateSafetyProbe(); } catch { return null; }
    }
    if (!value || typeof value !== "object" || value.schemaVersion !== 1
      || typeof value.ready !== "boolean" || typeof value.dirty !== "boolean"
      || typeof value.busy !== "boolean" || typeof value.blocked !== "boolean"
      || !Number.isFinite(value.updatedAt) || value.updatedAt > Date.now() + 1_000
      || Date.now() - value.updatedAt > FRESH_MS) return null;
    return value;
  }
  const clean = (value) => value?.ready === true && !value.dirty && !value.busy && !value.blocked
    && typeof window.utenWebUpdateSafetyProbe === "function";
  function branding() {
    const text = (value) => typeof value === "string" && value.trim().length > 0
      && value.length <= 160 && !/[\u0000-\u001f\u007f]/.test(value);
    let value = window.utenWebUpdateBranding;
    if (!value || value.schemaVersion !== 1 || !text(value.companyName) || !text(value.platformName)) value = DEFAULT_BRANDING;
    return { companyName: value.companyName.trim(), platformName: value.platformName.trim() };
  }
  function renderBranding() {
    if (!brandParts) return;
    const value = branding(), signature = JSON.stringify(value);
    if (signature === brandSignature) return;
    brandSignature = signature;
    brandParts.company.textContent = value.companyName;
    brandParts.platform.textContent = value.platformName;
  }
  function removeModal(restoreFocus = true) {
    modal?.remove();
    modal = message = latestVersion = autoChoice = primary = secondary = undefined;
    countdownRow = countdownValue = undefined;
    brandParts = brandSignature = undefined;
    deadline = undefined;
    if (restoreFocus && previousFocus?.isConnected && typeof previousFocus.focus === "function") {
      previousFocus.focus({ preventScroll: true });
    }
    previousFocus = undefined;
  }
  function continueWork() {
    if (target && !clean(safety())) deferredUnsafe = token(target);
    lastActivity = Date.now();
    transientMessage = undefined;
    removeModal();
  }
  function render() {
    if (!modal || !target) return;
    latestVersion.textContent = "（" + target.version + "）";
    const state = safety();
    if (!clean(state)) deadline = undefined;
    autoChoice.checked = autoWhenIdle;
    primary.disabled = refreshing || !clean(state);
    const remaining = deadline === undefined ? 0 : Math.max(0, Math.ceil((deadline - Date.now()) / 1_000));
    // The big countdown is the live element; keep it the only ticking number.
    if (countdownRow) {
      countdownRow.hidden = deadline === undefined;
      if (deadline !== undefined) countdownValue.textContent = String(remaining);
    }
    primary.textContent = refreshing ? "正在核对…"
      : deadline !== undefined ? "已保存，立即刷新（" + remaining + " 秒）"
      : "已保存，立即刷新";
    if (transientMessage) message.textContent = transientMessage;
    else if (!state || !state.ready) message.textContent = "正在确认当前工作状态，确认完成后才会刷新。你可以继续工作。";
    else if (state.dirty) message.textContent = "还有未保存的内容，请保存后再刷新。你可以继续编辑，系统会等待。";
    else if (state.busy || state.blocked) message.textContent = "当前操作尚未完成，系统会等待。完成操作后再刷新即可。";
    else if (!autoWhenIdle) message.textContent = "空闲时自动更新已关闭。当前内容已保存，可以手动刷新至 " + target.version + "。";
    else if (deadline !== undefined) message.textContent = "当前内容已保存，页面已空闲，即将自动更新至 " + target.version + "。";
    else if (attempted(target)) message.textContent = "刚才的更新尚未完成。当前内容已保存，可以重试刷新。";
    else message.textContent = "当前内容已保存，可以刷新至 " + target.version + "。继续工作后，系统会等到页面空闲再更新。";
  }
  function show() {
    if (modal || !target) return;
    previousFocus = document.activeElement;
    modal = document.createElement("div"); modal.id = DIALOG_ID;
    const card = document.createElement("section"); card.className = "uten-web-update-card";
    card.setAttribute("role", "dialog"); card.setAttribute("aria-modal", "true");
    card.setAttribute("aria-labelledby", "uten-web-update-title"); card.setAttribute("aria-describedby", "uten-web-update-message");
    const brand = document.createElement("header"); brand.className = "uten-web-update-brand";
    const company = document.createElement("strong");
    const platform = document.createElement("span");
    brandParts = { company, platform }; renderBranding();
    brand.append(company, platform);
    const title = document.createElement("h2"); title.id = "uten-web-update-title"; title.textContent = "有新的版本";
    latestVersion = document.createElement("span"); latestVersion.id = "uten-web-update-latest-version";
    title.append(latestVersion);
    const suggestion = document.createElement("p"); suggestion.className = "uten-web-update-suggestion";
    suggestion.textContent = "建议立即更新。";
    const currentVersion = document.createElement("p"); currentVersion.className = "uten-web-update-current-version";
    const currentValue = document.createElement("span"); currentValue.id = "uten-web-update-current-version";
    currentVersion.textContent = "当前版本 "; currentValue.textContent = baseline; currentVersion.append(currentValue);
    message = document.createElement("p"); message.id = "uten-web-update-message";
    message.setAttribute("aria-live", "polite"); message.setAttribute("aria-atomic", "true");
    countdownRow = document.createElement("p"); countdownRow.className = "uten-web-update-countdown"; countdownRow.hidden = true;
    countdownValue = document.createElement("strong"); countdownValue.id = "uten-web-update-countdown";
    const countdownLabel = document.createElement("span"); countdownLabel.textContent = "秒后自动更新";
    countdownRow.append(countdownValue, countdownLabel);
    const preference = document.createElement("label"); preference.className = "uten-web-update-preference";
    autoChoice = document.createElement("input"); autoChoice.type = "checkbox";
    autoChoice.id = "uten-web-update-auto-idle"; autoChoice.checked = autoWhenIdle;
    autoChoice.addEventListener("change", () => setAutoWhenIdle(autoChoice.checked, true));
    const preferenceText = document.createElement("span"); preferenceText.textContent = "空闲时自动更新";
    preference.append(autoChoice, preferenceText);
    const actions = document.createElement("div"); actions.className = "uten-web-update-actions";
    secondary = document.createElement("button"); secondary.type = "button"; secondary.className = "uten-web-update-secondary";
    secondary.textContent = "继续工作"; secondary.addEventListener("click", continueWork);
    primary = document.createElement("button"); primary.type = "button"; primary.className = "uten-web-update-primary";
    primary.addEventListener("click", () => { void refresh(true); });
    actions.append(secondary, primary); card.append(brand, title, suggestion, currentVersion, message, countdownRow, preference, actions);
    card.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); continueWork(); }
      if (event.key === "Tab") {
        const first = autoChoice, last = primary.disabled ? secondary : primary;
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    });
    modal.append(card); document.body.append(modal); render(); secondary.focus({ preventScroll: true });
  }
  function activity(event) {
    lastActivity = Date.now(); deferredUnsafe = transientMessage = undefined;
    if (deadline !== undefined) {
      deadline = undefined;
      if (!modal?.contains(event.target)) removeModal(); else render();
    }
  }
  function setAutoWhenIdle(value, persist) {
    autoWhenIdle = value; deadline = undefined; lastActivity = Date.now(); transientMessage = undefined;
    if (persist) {
      try { window.localStorage.setItem(AUTO_IDLE_KEY, String(value)); } catch { /* Keep the user's choice for this page. */ }
    }
    render();
  }
  async function refresh(manual) {
    if (!target || navigating || refreshing) return;
    if (!clean(safety()) || (!manual && (!autoWhenIdle || Date.now() - lastActivity < IDLE_MS))) { deadline = undefined; render(); return; }
    refreshing = true; deadline = undefined; render();
    const latest = await metadata();
    if (latest?.version === baseline) { target = undefined; refreshing = false; removeModal(); return; }
    // Ask Dart again after the network wait, immediately before navigation.
    if (latest && clean(safety(true)) && (manual || autoWhenIdle && Date.now() - lastActivity >= IDLE_MS)) {
      target = latest;
      if (navigate(latest, manual)) return;
    }
    refreshing = false;
    retryAfter = Date.now() + CHECK_MS;
    transientMessage = latest ? undefined : "暂时无法确认最新版本，当前工作会保留。联网后可以重试刷新。";
    render();
  }
  function tick() {
    if (!target || navigating || refreshing) return;
    const state = safety(), idle = Date.now() - lastActivity >= IDLE_MS;
    if (deadline !== undefined && (!autoWhenIdle || !idle || !clean(state))) deadline = undefined;
    if (idle && !modal && (clean(state) || deferredUnsafe !== token(target))) show();
    if (autoWhenIdle && idle && clean(state) && deadline === undefined && Date.now() >= retryAfter && !attempted(target)) deadline = Date.now() + COUNTDOWN_MS;
    render();
    if (deadline !== undefined && Date.now() >= deadline) void refresh(false);
  }
  async function check() {
    if (!stamped || navigating) return;
    const value = await metadata();
    if (!value) return;
    if (value.version === baseline) { target = undefined; transientMessage = undefined; removeModal(); return; }
    if (!target || token(target) !== token(value)) { removeModal(); target = value; deferredUnsafe = transientMessage = undefined; }
    tick();
  }
  // Ordered ahead of Flutter: a stale fresh entry has no live editor yet.
  window.utenWebUpdateGate = (async () => {
    if (!stamped) return { navigating: false };
    const value = await metadata();
    if (value && value.version !== baseline) { target = value; if (navigate(value)) return { navigating: true }; }
    return { navigating: false };
  })();
  if (!stamped) return;
  for (const name of ["pointerdown", "pointermove", "keydown", "input", "paste", "compositionstart", "wheel", "touchstart"]) {
    document.addEventListener(name, activity, { capture: true, passive: true });
  }
  window.setInterval(tick, 1_000);
  window.setInterval(() => { void check(); }, CHECK_MS);
  window.addEventListener("online", () => { void check(); });
  window.addEventListener("uten:web-update-safety", tick);
  window.addEventListener("uten:web-update-branding", renderBranding);
  window.addEventListener("storage", (event) => {
    if (event.key !== AUTO_IDLE_KEY) return;
    if (event.newValue === "false") setAutoWhenIdle(false, false);
    else if (event.newValue === "true" || event.newValue === null) setAutoWhenIdle(true, false);
  });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") { tick(); void check(); } });
})();
