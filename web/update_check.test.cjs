const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "update_check.js"), "utf8");
const flush = () => new Promise((resolve) => setImmediate(resolve));
function release(version, sequence = 100001001001, sha = "a".repeat(40)) {
  return { commitSha: sha, product: "uten-imp", releaseSequence: sequence, schemaVersion: 1, version };
}
async function checker(options = {}) {
  let now = 1_000_000, nextTimer = 0, remote = options.remote ?? release(options.baseline ?? "v1.1.0");
  let fetcher = options.fetcher, probe, probeCount = 0;
  const timers = new Map(), storage = options.storage ?? new Map(), preferences = options.preferences ?? new Map(), requests = [], navigations = [];
  const documentListeners = new Map(), windowListeners = new Map();
  const add = (map, name, fn) => { if (!map.has(name)) map.set(name, []); map.get(name).push(fn); };
  const walk = (node) => [node, ...node.children.flatMap(walk)];
  const document = {
    baseURI: "https://erp.example.internal/erp/", visibilityState: "visible",
    addEventListener(name, fn) { add(documentListeners, name, fn); },
    querySelector() { return { getAttribute: () => options.baseline ?? "v1.1.0" }; },
    getElementById(id) { return walk(this.body).find((node) => node.id === id); },
    createElement(tag) {
      const node = {
        tagName: tag, children: [], attributes: new Map(), listeners: new Map(), disabled: false,
        append(...children) { for (const child of children) { child.parent = this; this.children.push(child); } },
        addEventListener(name, fn) { add(this.listeners, name, fn); },
        setAttribute(name, value) { this.attributes.set(name, value); },
        remove() { if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = undefined; },
        contains(child) { return walk(this).includes(child); },
        focus() { document.activeElement = this; },
        get isConnected() { return document.body.contains(this); },
      };
      return node;
    },
  };
  document.body = document.createElement("body");
  document.activeElement = document.body;
  const setTimer = (fn, ms, period) => { const id = ++nextTimer; timers.set(id, { fn, at: now + ms, period }); return id; };
  const window = {
    addEventListener(name, fn) { add(windowListeners, name, fn); },
    location: {
      href: options.href ?? "https://erp.example.internal/erp/?tenant=company#/basicinfo?returnTo=/dashboard",
      replace(url) { navigations.push(url); this.href = url; },
    },
    sessionStorage: {
      getItem(key) { if (options.blockStorage) throw Error("blocked"); return storage.get(key) ?? null; },
      setItem(key, value) { if (options.blockStorage) throw Error("blocked"); storage.set(key, value); },
    },
    localStorage: {
      getItem(key) { if (options.blockStorage) throw Error("blocked"); return preferences.get(key) ?? null; },
      setItem(key, value) { if (options.blockStorage) throw Error("blocked"); preferences.set(key, value); },
    },
    setTimeout(fn, ms) { return setTimer(fn, ms); },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn, ms) { return setTimer(fn, ms, ms); },
  };
  if (options.branding) window.utenWebUpdateBranding = options.branding;
  function publish(values = {}) {
    window.utenWebUpdateSafety = {
      schemaVersion: 1, ready: true, dirty: false, busy: false, blocked: false, updatedAt: now, ...values,
    };
    for (const listener of windowListeners.get("uten:web-update-safety") ?? []) listener();
  }
  function installBridge(values = {}, heartbeat = true) {
    publish(values);
    window.utenWebUpdateSafetyProbe = () => {
      probeCount++;
      if (probe) return probe();
      publish({ ...window.utenWebUpdateSafety, updatedAt: now });
      return window.utenWebUpdateSafety;
    };
    if (heartbeat) window.setInterval(() => {
      if (window.utenWebUpdateSafety) window.utenWebUpdateSafety.updatedAt = now;
    }, 2_000);
  }
  if (options.bridge !== false) installBridge(options.safety);
  const clockDate = class extends Date { static now() { return now; } };
  vm.runInNewContext(source, {
    URL, Date: clockDate, AbortController, document, window,
    fetch: async (url, init) => {
      requests.push({ url: url.toString(), init });
      if (fetcher) return await fetcher(url, init);
      if (remote instanceof Error) throw remote;
      return { ok: true, json: async () => remote };
    },
  }, { filename: "update_check.js" });
  await flush(); await flush();
  const api = {
    document, window, storage, preferences, requests, navigations, publish, installBridge,
    get now() { return now; }, get probeCount() { return probeCount; },
    get dialog() { return document.getElementById("uten-web-update-dialog"); },
    get primary() { return walk(document.body).find((node) => node.className === "uten-web-update-primary"); },
    get secondary() { return walk(document.body).find((node) => node.className === "uten-web-update-secondary"); },
    get message() { return document.getElementById("uten-web-update-message")?.textContent; },
    get autoChoice() { return document.getElementById("uten-web-update-auto-idle"); },
    async chooseAuto(value) {
      this.autoChoice.checked = value;
      await this.event("change", { target: this.autoChoice });
    },
    async storageEvent(key, newValue) {
      for (const listener of windowListeners.get("storage") ?? []) listener({ key, newValue });
      await flush();
    },
    publishBrand(value) {
      window.utenWebUpdateBranding = value;
      for (const listener of windowListeners.get("uten:web-update-branding") ?? []) listener();
    },
    setRemote(value) { remote = value; }, setFetch(fn) { fetcher = fn; }, setProbe(fn) { probe = fn; },
    async event(name, values = {}) {
      const event = { target: values.target ?? document.body, preventDefault() { this.prevented = true; }, ...values };
      for (const fn of documentListeners.get(name) ?? []) fn(event);
      for (const fn of event.target.listeners?.get(name) ?? []) fn(event);
      await flush(); return event;
    },
    async online() { for (const fn of windowListeners.get("online") ?? []) fn(); await flush(); await flush(); },
    async click(node) {
      if (node.disabled) return;
      await this.event("pointerdown", { target: node });
      for (const fn of node.listeners.get("click") ?? []) fn();
      await flush(); await flush();
    },
    async advance(ms) {
      const end = now + ms;
      for (let count = 0; count < 10_000; count++) {
        let found;
        for (const [id, timer] of timers) if (timer.at <= end && (!found || timer.at < found[1].at)) found = [id, timer];
        if (!found) { now = end; await flush(); return; }
        now = found[1].at;
        if (found[1].period) found[1].at += found[1].period; else timers.delete(found[0]);
        found[1].fn(); await flush();
      }
      throw Error("timer loop");
    },
  };
  return api;
}
async function pending(options = {}) {
  const app = await checker(options);
  app.setRemote(release("v1.1.1"));
  await app.online();
  return app;
}
test("unstamped development entry starts without update requests", async () => {
  const app = await checker({ baseline: "__UTEN_RELEASE_VERSION__", remote: release("v1.1.1") });
  assert.equal(app.requests.length, 0);
  assert.equal((await app.window.utenWebUpdateGate).navigating, false);
});
test("matching release starts Flutter without a dialog or navigation", async () => {
  const app = await checker();
  assert.equal(app.requests.length, 1);
  assert.equal((await app.window.utenWebUpdateGate).navigating, false);
  assert.equal(app.dialog, undefined);
  assert.equal(app.navigations.length, 0);
  assert.equal(app.requests[0].init.credentials, "same-origin");
  assert.equal(app.requests[0].init.cache, "no-store");
});
test("fresh stale entry checks before Flutter and preserves origin, base path, query, hash and storage", async () => {
  const storage = new Map([["company-draft", "retained"], ["server", "company"]]);
  const app = await checker({ remote: release("v1.1.1"), storage });
  assert.equal((await app.window.utenWebUpdateGate).navigating, true);
  const url = new URL(app.navigations[0]);
  assert.equal(url.origin, "https://erp.example.internal");
  assert.equal(url.pathname, "/erp/");
  assert.equal(url.searchParams.get("tenant"), "company");
  assert.equal(url.hash, "#/basicinfo?returnTo=/dashboard");
  assert.equal(url.searchParams.get("uten-web-release"), "v1.1.1:" + "a".repeat(40));
  assert.equal(storage.get("company-draft"), "retained");
  assert.equal(storage.get("server"), "company");
});
test("release rollback remains an eligible version change", async () => {
  const app = await checker({ baseline: "v1.1.2", remote: release("v1.1.1") });
  assert.equal(app.navigations.length, 1);
});
test("metadata rejects malformed, extra-field, unsafe-number and unsigned-looking responses", async () => {
  for (const value of [{ version: "v1.1.1" }, { ...release("v1.1.1"), extra: true },
    { ...release("v1.1.1"), releaseSequence: Number.MAX_SAFE_INTEGER + 1 },
    { ...release("v1.1.1"), commitSha: "short" }, release("1.1.1"), release("v01.1.1")]) {
    const app = await checker({ remote: value });
    assert.equal(app.navigations.length, 0);
    assert.equal((await app.window.utenWebUpdateGate).navigating, false);
  }
});
test("unavailable metadata allows startup and a later online check recovers", async () => {
  const app = await checker({ remote: new Error("offline") });
  assert.equal((await app.window.utenWebUpdateGate).navigating, false);
  app.setRemote(release("v1.1.1"));
  await app.online(); await app.advance(60_000);
  assert.ok(app.dialog);
});
test("hanging metadata is bounded before Flutter startup", async () => {
  const app = await checker({ fetcher: () => new Promise(() => {}) });
  let allowedToStart = false;
  app.window.utenWebUpdateGate.then(() => { allowedToStart = true; });
  await app.advance(3_999); assert.equal(allowedToStart, false);
  await app.advance(1); assert.equal(allowedToStart, true);
  assert.equal(app.navigations.length, 0);
  app.setFetch(undefined); app.setRemote(release("v1.1.1")); await app.online();
  await app.advance(56_000);
  assert.ok(app.dialog);
});
test("idle saved page shows centered company dialog then probes and refreshes after ten seconds", async () => {
  const app = await pending();
  await app.advance(59_000); assert.equal(app.dialog, undefined);
  await app.advance(1_000); assert.ok(app.dialog);
  const card = app.dialog.children[0];
  assert.equal(card.attributes.get("role"), "dialog");
  assert.equal(card.attributes.get("aria-modal"), "true");
  assert.equal(card.children[0].children[0].textContent, "中山市优腾电器有限公司");
  assert.equal(app.document.getElementById("uten-web-update-title").textContent, "有新的版本");
  assert.equal(app.document.getElementById("uten-web-update-latest-version").textContent, "（v1.1.1）");
  assert.equal(card.children[2].textContent, "建议立即更新。");
  const countdownRow = card.children[5];
  assert.equal(countdownRow.className, "uten-web-update-countdown");
  assert.equal(countdownRow.hidden, false);
  assert.equal(countdownRow.children[0].textContent, "10");
  assert.equal(countdownRow.children[1].textContent, "秒后自动更新");
  assert.match(app.message, /即将自动更新至 v1\.1\.1/);
  assert.match(app.primary.textContent, /已保存，立即刷新（10 秒）/);
  await app.advance(5_000);
  assert.equal(app.document.getElementById("uten-web-update-countdown").textContent, "5");
  assert.match(app.primary.textContent, /已保存，立即刷新（5 秒）/);
  await app.advance(4_000); assert.equal(app.navigations.length, 0);
  await app.advance(1_000); assert.equal(app.navigations.length, 1); assert.equal(app.probeCount, 1);
});
test("typing, pointer movement and wheel activity restart the full idle period", async () => {
  for (const name of ["input", "keydown", "pointermove", "wheel", "compositionstart"]) {
    const app = await pending();
    await app.advance(69_000); await app.event(name);
    await app.advance(59_000);
    assert.equal(app.navigations.length, 0, name); assert.equal(app.dialog, undefined, name);
    await app.advance(1_000); assert.ok(app.dialog, name);
  }
});
test("dirty, busy and blocked work cannot refresh automatically or manually", async () => {
  for (const field of ["dirty", "busy", "blocked"]) {
    const app = await pending({ safety: { [field]: true } });
    await app.advance(130_000);
    assert.equal(app.navigations.length, 0, field);
    assert.equal(app.document.getElementById("uten-web-update-current-version").textContent, "v1.1.0");
    assert.equal(app.document.getElementById("uten-web-update-latest-version").textContent, "（v1.1.1）");
    assert.equal(app.primary.disabled, true, field);
    await app.click(app.primary); assert.equal(app.navigations.length, 0, field);
    app.publish(); await app.advance(10_000); assert.equal(app.navigations.length, 1, field);
  }
});
test("missing, stale, future and malformed bridge snapshots fail closed", async () => {
  for (const kind of ["missing", "stale", "future", "malformed", "probe-missing"]) {
    const app = await pending({ bridge: false });
    if (kind !== "missing") {
      app.installBridge({}, false);
      if (kind === "future") app.window.utenWebUpdateSafety.updatedAt = app.now + 500_000;
      if (kind === "malformed") app.window.utenWebUpdateSafety.dirty = "false";
      if (kind === "probe-missing") delete app.window.utenWebUpdateSafetyProbe;
    }
    await app.advance(130_000);
    assert.equal(app.navigations.length, 0, kind);
    assert.equal(app.primary.disabled, true, kind);
  }
});
test("new dirty state during countdown cancels it immediately", async () => {
  const app = await pending(); await app.advance(69_000);
  app.publish({ dirty: true }); await app.advance(1_000);
  assert.equal(app.navigations.length, 0); assert.match(app.message, /未保存/);
  assert.equal(app.primary.disabled, true);
});
test("a bridge that expires during the countdown cancels automatic refresh", async () => {
  const app = await pending({ bridge: false }); await app.advance(60_000);
  app.installBridge({ updatedAt: app.now - 23_000 }, false);
  await app.advance(10_000);
  assert.equal(app.navigations.length, 0);
  assert.equal(app.primary.disabled, true);
});
test("final synchronous probe protects a draft created after the last heartbeat", async () => {
  const app = await pending();
  app.setProbe(() => {
    app.publish({ dirty: true });
    return app.window.utenWebUpdateSafety;
  });
  await app.advance(70_000);
  assert.equal(app.probeCount, 1); assert.equal(app.navigations.length, 0);
  assert.equal(app.primary.disabled, true);
});
test("probe failure prevents refresh without touching user storage", async () => {
  const app = await pending(); app.storage.set("draft", "keep");
  app.setProbe(() => { throw Error("registry unavailable"); });
  await app.advance(70_000);
  assert.equal(app.navigations.length, 0); assert.equal(app.storage.get("draft"), "keep");
});
test("activity during the final metadata request cancels automatic navigation", async () => {
  const app = await pending(); await app.advance(69_000);
  let complete;
  app.setFetch(() => new Promise((resolve) => { complete = resolve; }));
  await app.advance(1_000); assert.ok(complete);
  await app.event("input");
  complete({ ok: true, json: async () => release("v1.1.1") });
  await flush(); await flush();
  assert.equal(app.navigations.length, 0);
});
test("manual refresh can ignore idle time but still probes current saved state", async () => {
  const app = await pending(); await app.advance(60_000);
  await app.click(app.primary);
  assert.equal(app.navigations.length, 1); assert.equal(app.probeCount, 1);
});
test("manual refresh rechecks work that becomes busy during metadata validation", async () => {
  const app = await pending(); await app.advance(60_000);
  let complete;
  app.setFetch(() => new Promise((resolve) => { complete = resolve; }));
  await app.click(app.primary); assert.ok(complete);
  app.publish({ busy: true });
  complete({ ok: true, json: async () => release("v1.1.1") });
  await flush(); await flush();
  assert.equal(app.navigations.length, 0);
  assert.equal(app.primary.disabled, true);
});
test("fresh URL marker prevents reload loops even with blocked storage", async () => {
  const first = await checker({ remote: release("v1.1.1"), blockStorage: true });
  const second = await checker({ remote: release("v1.1.1"), href: first.navigations[0], blockStorage: true });
  assert.equal((await second.window.utenWebUpdateGate).navigating, false);
  await second.advance(180_000);
  assert.equal(second.navigations.length, 0);
  assert.match(second.message, /尚未完成/);
  await second.click(second.primary); assert.equal(second.navigations.length, 1);
});
test("session attempt also prevents repeated automatic navigation of another stale entry", async () => {
  const first = await checker({ remote: release("v1.1.1") });
  const second = await checker({ remote: release("v1.1.1"), storage: first.storage });
  assert.equal(second.navigations.length, 0);
  await second.advance(120_000); assert.equal(second.navigations.length, 0);
});
test("Escape returns focus to existing work and does not clear preferences", async () => {
  const app = await pending();
  const input = app.document.createElement("input"); app.document.body.append(input); input.focus();
  app.storage.set("preferences", "keep"); await app.advance(60_000);
  const card = app.dialog.children[0];
  const event = await app.event("keydown", { target: card, key: "Escape" });
  assert.equal(event.prevented, true); assert.equal(app.dialog, undefined);
  assert.equal(app.document.activeElement, input); assert.equal(app.storage.get("preferences"), "keep");
});
test("keyboard focus stays within the dialog until continue work", async () => {
  const app = await pending(); await app.advance(60_000);
  assert.equal(app.document.activeElement, app.secondary);
  const card = app.dialog.children[0];
  app.autoChoice.focus();
  await app.event("keydown", { target: card, key: "Tab", shiftKey: true });
  assert.equal(app.document.activeElement, app.primary);
  await app.event("keydown", { target: card, key: "Tab", shiftKey: false });
  assert.equal(app.document.activeElement, app.autoChoice);
  await app.click(app.secondary); assert.equal(app.dialog, undefined);
});
test("a transient runtime check failure preserves the pending update and backs off retries", async () => {
  const app = await pending(); await app.advance(69_000);
  app.setRemote(new Error("offline")); await app.advance(1_000);
  assert.equal(app.navigations.length, 0); assert.match(app.message, /暂时无法确认/);
  const requests = app.requests.length;
  await app.advance(15_000); assert.equal(app.requests.length, requests);
});
test("a server rollback to the loaded version cancels the pending update", async () => {
  const app = await pending(); await app.advance(60_000);
  app.setRemote(release("v1.1.0")); await app.online();
  assert.equal(app.dialog, undefined); await app.advance(20_000);
  assert.equal(app.navigations.length, 0);
});
test("company settings update the open dialog through the shared branding snapshot", async () => {
  const app = await pending(); await app.advance(60_000);
  app.publishBrand({ schemaVersion: 1, companyName: "更新后的公司名称", platformName: "公司业务平台" });
  const brand = app.dialog.children[0].children[0];
  assert.equal(brand.children[0].textContent, "更新后的公司名称");
  assert.equal(brand.children[1].textContent, "公司业务平台");
});
test("the update dialog never creates or requests logos, including old branding artwork fields", async () => {
  for (const logoSrc of ["https://attacker.example/logo.png",
    "/api/platform/branding/logo?v=7", "assets/assets/images/logo_name.png", null]) {
    const app = await pending({ branding: { schemaVersion: 1, companyName: "自有公司", platformName: "自有平台",
      logoSrc, usesDefaultArtwork: false } });
    await app.advance(60_000);
    const all = (node) => [node, ...node.children.flatMap(all)];
    assert.equal(all(app.dialog).some((node) => node.tagName === "img"), false);
    assert.equal(app.requests.every((request) => new URL(request.url).pathname.endsWith("/version.json")), true);
  }
});
test("invalid branding falls back to the confirmed company and treats names as plain text", async () => {
  const app = await pending({ branding: { schemaVersion: 1, companyName: "X".repeat(161), platformName: "平台",
    logoSrc: null, usesDefaultArtwork: false } });
  await app.advance(60_000);
  let brand = app.dialog.children[0].children[0];
  assert.equal(brand.children[0].textContent, "中山市优腾电器有限公司");
  app.publishBrand({ schemaVersion: 1, companyName: "<img src=bad onerror=alert(1)>", platformName: "平台",
    logoSrc: null, usesDefaultArtwork: false });
  assert.equal(brand.children[0].textContent, "<img src=bad onerror=alert(1)>");
  assert.equal(brand.children.length, 2);
});
test("idle automatic update is checked by default and can be disabled without disabling safe manual refresh", async () => {
  const app = await pending(); await app.advance(60_000);
  assert.equal(app.autoChoice.checked, true);
  await app.chooseAuto(false); await app.advance(120_000);
  assert.equal(app.navigations.length, 0);
  assert.equal(app.autoChoice.checked, false);
  assert.match(app.message, /自动更新已关闭/);
  assert.equal(app.preferences.get("uten.webUpdate.autoWhenIdle"), "false");
  await app.click(app.primary); assert.equal(app.navigations.length, 1);
});
test("an explicit idle update preference persists while unrelated preferences are preserved", async () => {
  const preferences = new Map([["company-setting", "keep"]]);
  const first = await pending({ preferences }); await first.advance(60_000); await first.chooseAuto(false);
  const second = await pending({ preferences }); await second.advance(120_000);
  assert.equal(second.autoChoice.checked, false);
  assert.equal(second.navigations.length, 0);
  assert.equal(preferences.get("company-setting"), "keep");
  const freshEntry = await checker({ preferences, remote: release("v1.1.1") });
  assert.equal(freshEntry.navigations.length, 1, "fresh-entry startup remains independent of the idle checkbox");
});
test("blocked local storage still allows the page's in-memory idle preference", async () => {
  const app = await pending({ blockStorage: true }); await app.advance(60_000);
  await app.chooseAuto(false); await app.advance(120_000);
  assert.equal(app.autoChoice.checked, false); assert.equal(app.navigations.length, 0);
});
test("turning idle updates back on waits for the full idle interval and grace countdown", async () => {
  const app = await pending(); await app.advance(60_000);
  await app.chooseAuto(false); await app.advance(120_000); await app.chooseAuto(true);
  await app.advance(69_000); assert.equal(app.navigations.length, 0);
  await app.advance(1_000); assert.equal(app.navigations.length, 1);
});
test("turning idle updates off during the final metadata request cancels navigation", async () => {
  const app = await pending(); await app.advance(69_000);
  let complete;
  app.setFetch(() => new Promise((resolve) => { complete = resolve; }));
  await app.advance(1_000); assert.ok(complete);
  await app.chooseAuto(false);
  complete({ ok: true, json: async () => release("v1.1.1") });
  await flush(); await flush();
  assert.equal(app.navigations.length, 0);
  assert.equal(app.autoChoice.checked, false);
});
test("cross-tab idle preference changes cancel countdowns and ignore unrelated storage events", async () => {
  const app = await pending(); await app.advance(69_000);
  await app.storageEvent("other-feature-setting", "false"); assert.equal(app.autoChoice.checked, true);
  await app.storageEvent("uten.webUpdate.autoWhenIdle", "false"); await app.advance(1_000);
  assert.equal(app.autoChoice.checked, false); assert.equal(app.navigations.length, 0);
  await app.storageEvent("uten.webUpdate.autoWhenIdle", "true");
  await app.advance(69_000); assert.equal(app.navigations.length, 0);
  await app.advance(1_000); assert.equal(app.navigations.length, 1);
});
test("custom bootstrap waits for the entry gate and preserves renderer, fonts and service worker config", async () => {
  const bootstrap = fs.readFileSync(path.join(__dirname, "flutter_bootstrap.js"), "utf8")
    .replace("{{flutter_js}}", "").replace("{{flutter_build_config}}", "")
    .replace("{{flutter_service_worker_version}}", '"test-version"');
  let finish, calls = [];
  const gate = new Promise((resolve) => { finish = resolve; });
  vm.runInNewContext(bootstrap, { URL, document: { baseURI: "https://erp.example.internal/erp/" },
    window: { utenWebUpdateGate: gate }, _flutter: { loader: { load: (config) => calls.push(config) } } });
  await flush(); assert.equal(calls.length, 0);
  finish({ navigating: false }); await flush();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].config.canvasKitVariant, "full");
  assert.equal(calls[0].config.fontFallbackBaseUrl, "https://erp.example.internal/erp/fallback_fonts/");
  assert.equal(calls[0].serviceWorkerSettings.serviceWorkerVersion, "test-version");
  calls = [];
  vm.runInNewContext(bootstrap, { URL, document: { baseURI: "https://erp.example.internal/" },
    window: { utenWebUpdateGate: Promise.resolve({ navigating: true }) },
    _flutter: { loader: { load: (config) => calls.push(config) } } });
  await flush(); assert.equal(calls.length, 0);
  const index = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
  assert.match(index, /src="update_check\.js" defer/);
  assert.match(index, /src="flutter_bootstrap\.js" defer/);
  assert.ok(index.indexOf('src="update_check.js"') < index.indexOf('src="flutter_bootstrap.js"'));
});
