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
  let fetcher = options.fetcher, probe, probeCount = 0, prepare = options.prepare, prepareCount = 0;
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
      schemaVersion: 1, ready: true, dirty: false, busy: false, blocked: false, serverReloadSafe: true, updatedAt: now, ...values,
    };
    for (const listener of windowListeners.get("uten:web-update-safety") ?? []) listener();
  }
  function installBridge(values = {}, heartbeat = true) {
    window.utenWebServerMaintenance = {schemaVersion:1,state:'available',noticeKey:'',updatedAt:now};
    window.utenWebUpdatePrepare = async () => { prepareCount++; return prepare ? await prepare() : true; };
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
      if (new URL(url).pathname === '/actuator/health/readiness') return { ok: true, json: async () => ({ status: 'UP' }) };
      if (remote instanceof Error) throw remote;
      return { ok: true, json: async () => remote };
    },
  }, { filename: "update_check.js" });
  await flush(); await flush();
  const api = {
    document, window, storage, preferences, requests, navigations, publish, installBridge,
    get now() { return now; }, get probeCount() { return probeCount; }, get prepareCount() { return prepareCount; },
    get surface() { return document.getElementById('uten-web-update-status'); },
    async server(state, noticeKey = 'notice-1') {
      window.utenWebServerMaintenance = { schemaVersion: 1, state, noticeKey, updatedAt: now };
      for (const listener of windowListeners.get('uten:web-server-maintenance') ?? []) listener();
      await flush(); await flush();
    },
    setPrepare(fn) { prepare = fn; },
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

test("unstamped development entry starts without update requests", async () => {
  const app = await checker({ baseline: "__UTEN_RELEASE_VERSION__" });
  assert.equal(app.requests.length, 0);
  assert.equal((await app.window.utenWebUpdateGate).navigating, false);
});
test("matching entry starts Flutter without any update choice", async () => {
  const app = await checker();
  assert.equal(app.requests.length, 1);
  assert.equal((await app.window.utenWebUpdateGate).navigating, false);
  assert.equal(app.surface, undefined);
  assert.equal(app.requests[0].init.cache, "no-store");
});
test("a stale fresh entry updates before Flutter, preserving deep link and stored session/drafts", async () => {
  const storage = new Map([["company-draft", "retained"], ["session", "retained"]]);
  const app = await checker({ remote: release("v1.1.1"), storage });
  assert.equal((await app.window.utenWebUpdateGate).navigating, true);
  const url = new URL(app.navigations[0]);
  assert.equal(url.origin, "https://erp.example.internal");
  assert.equal(url.pathname, "/erp/");
  assert.equal(url.searchParams.get("tenant"), "company");
  assert.equal(url.hash, "#/basicinfo?returnTo=/dashboard");
  assert.equal(storage.get("company-draft"), "retained");
  assert.equal(storage.get("session"), "retained");
});
test("rollback is an eligible release replacement", async () => {
  const app = await checker({ baseline: "v1.1.2", remote: release("v1.1.1") });
  assert.equal(app.navigations.length, 1);
});
test("invalid or unavailable release metadata never navigates", async () => {
  for (const remote of [new Error("offline"), {version: "v1.1.1"}, { ...release("v1.1.1"), extra: true },
    {...release("v1.1.1"), releaseSequence: Number.MAX_SAFE_INTEGER + 1},
    {...release("v1.1.1"), commitSha: "short"}, release("1.1.1"), release("v01.1.1")]) {
    const app = await checker({ remote });
    assert.equal(app.navigations.length, 0);
    assert.equal((await app.window.utenWebUpdateGate).navigating, false);
  }
});
test("hanging metadata is bounded before Flutter startup", async () => {
  const app = await checker({ fetcher: () => new Promise(() => {}) });
  let started = false; app.window.utenWebUpdateGate.then(() => { started = true; });
  await app.advance(3999); assert.equal(started, false);
  await app.advance(1); assert.equal(started, true);
});
test("active use and the old opt-out cannot delay automatic server release replacement", async () => {
  const preferences = new Map([["uten.webUpdate.autoWhenIdle", "false"], ["theme", "keep"]]);
  const app = await checker({preferences});
  app.setRemote(release("v1.1.1"));
  await app.event("keydown"); await app.event("input"); await app.online();
  assert.equal(app.navigations.length, 1);
  assert.equal(app.prepareCount, 1);
  assert.equal(app.window.utenWebServerReloadAuthorized, true);
  assert.equal(app.autoChoice, undefined);
  assert.equal(app.primary, undefined);
  assert.equal(preferences.get("theme"), "keep");
});
test("maintenance covers an active page immediately and recovery automatically loads latest release", async () => {
  const app = await checker();
  const input = app.document.createElement("input"); app.document.body.append(input); input.focus();
  await app.server("updating");
  assert.ok(app.surface); assert.equal(input.inert, true);
  assert.match(app.message, /正在更新服务/);
  app.setRemote(release("v1.1.1"));
  await app.online(); await app.advance(15000);
  assert.equal(app.navigations.length, 0);
  await app.server("available");
  assert.equal(app.navigations.length, 1);
  assert.equal(app.prepareCount, 1);
});
test("same-version server restart refreshes once per maintenance notice", async () => {
  const storage = new Map();
  const app = await checker({storage});
  await app.server("updating"); await app.server("available");
  assert.equal(app.navigations.length, 1);
  const fresh = await checker({storage, href: app.navigations[0]});
  await fresh.server("available"); await fresh.advance(30000);
  assert.equal(fresh.navigations.length, 0);
  await fresh.server("updating", "notice-2"); await fresh.server("available", "notice-2");
  assert.equal(fresh.navigations.length, 1);
});
test("recovery-required, scheduled-after-maintenance and missing status never release the maintenance page", async () => {
  const app = await checker();
  await app.server("recovery_required");
  assert.match(app.message, /管理员恢复/);
  app.setRemote(release("v1.1.1"));
  await app.server("scheduled"); await app.advance(15000);
  assert.equal(app.navigations.length, 0);
  app.window.utenWebServerMaintenance = undefined;
  await app.advance(15000);
  assert.equal(app.navigations.length, 0);
});
test("a server-only scheduled notice does not masquerade as maintenance", async () => {
  const app = await checker(); await app.server("scheduled");
  assert.equal(app.surface, undefined); assert.equal(app.navigations.length, 0);
});
test("available alone cannot reload an unhealthy app", async () => {
  const app = await checker(); await app.server("updating");
  app.setRemote(release("v1.1.1"));
  app.setFetch(async (url) => ({ok: true, json: async () => new URL(url).pathname.endsWith("version.json") ? release("v1.1.1") : {status: "DOWN"}}));
  await app.server("available");
  assert.equal(app.navigations.length, 0); assert.equal(app.prepareCount, 0);
});
test("a renewed maintenance phase during readiness cancels stale recovery", async () => {
  const app = await checker(); await app.server("updating");
  let complete;
  app.setFetch(async (url) => new URL(url).pathname.endsWith("version.json")
    ? {ok:true, json:async()=>release("v1.1.1")}
    : await new Promise(resolve => {complete=resolve;}));
  await app.server("available"); assert.ok(complete);
  await app.server("updating", "notice-2");
  complete({ok:true, json:async()=>({status:"UP"})}); await flush();
  assert.equal(app.navigations.length, 0);
});
test("draft storage commit must finish before navigation even when input is locally autosaved", async () => {
  let commit;
  const app = await checker({safety:{dirty:true, serverReloadSafe:true}, prepare:()=>new Promise(resolve=>{commit=resolve;})});
  app.setRemote(release("v1.1.1")); await app.online();
  assert.ok(commit); assert.equal(app.navigations.length, 0);
  commit(true); await flush(); await flush();
  assert.equal(app.navigations.length, 1);
});
test("busy commands, unknown outcomes and failed checkpoints preserve reachable work and retry automatically", async () => {
  for (const safety of [{busy:true}, {blocked:true,serverReloadSafe:false}, {dirty:true,serverReloadSafe:false}]) {
    const app = await checker({safety});
    const input = app.document.createElement("input"); app.document.body.append(input); input.focus();
    app.setRemote(release("v1.1.1")); await app.online();
    assert.equal(app.navigations.length, 0);
    assert.equal(input.inert, undefined);
    assert.equal(app.document.activeElement, input);
    assert.equal(app.surface.className, "uten-web-update-waiting");
    app.publish({serverReloadSafe:true}); await app.advance(15000);
    assert.equal(app.navigations.length, 1);
  }
  const app = await checker({prepare:async()=>false});
  app.setRemote(release("v1.1.1")); await app.online();
  assert.equal(app.navigations.length, 0);
  app.setPrepare(async()=>true); await app.advance(15000);
  assert.equal(app.navigations.length, 1);
});
test("a final synchronous probe prevents a raced submission from being lost", async () => {
  const app = await checker();
  app.setProbe(()=>({schemaVersion:1,ready:true,serverReloadSafe:true,busy:true,updatedAt:app.now}));
  app.setRemote(release("v1.1.1")); await app.online();
  assert.equal(app.navigations.length, 0);
});
test("missing bridge cannot refresh a live page; installing it later recovers automatically", async () => {
  const app = await checker({bridge:false}); app.setRemote(release("v1.1.1")); await app.online();
  assert.equal(app.navigations.length, 0);
  app.installBridge(); await app.advance(15000); assert.equal(app.navigations.length, 1);
});
test("hidden tabs pause checks and update on returning to foreground", async () => {
  const app = await checker(); app.document.visibilityState="hidden";
  app.setRemote(release("v1.1.1")); await app.advance(30000);
  assert.equal(app.navigations.length, 0);
  app.document.visibilityState="visible"; await app.event("visibilitychange");
  assert.equal(app.navigations.length, 1);
});
test("blocked storage and stale HTML cannot cause an automatic reload loop", async () => {
  const app = await checker({blockStorage:true,remote:release("v1.1.1")});
  assert.equal(app.navigations.length, 1);
  const stale = await checker({blockStorage:true,href:app.navigations[0],remote:release("v1.1.1")});
  await stale.advance(60000);
  assert.equal(stale.navigations.length, 0);
});
test("branding remains plain text and requests never fetch logos or third-party resources", async () => {
  const app = await checker({branding:{schemaVersion:1,companyName:"<img src=bad>",platformName:"公司平台"}});
  await app.server("updating");
  const brand=app.surface.children[0].children[0];
  assert.equal(brand.children[0].textContent,"<img src=bad>");
  assert.equal(brand.children.length,2);
  assert.equal(app.requests.length,1);
});
test("hanging draft preparation is bounded and can recover on a later automatic check", async () => {
  const app = await checker({prepare:()=>new Promise(()=>{})});
  app.setRemote(release('v1.1.1')); await app.online();
  await app.advance(8000);
  assert.equal(app.navigations.length,0);
  assert.equal(app.surface.className,'uten-web-update-waiting');
  app.setPrepare(async()=>true); await app.advance(7000);
  assert.equal(app.navigations.length,1);
});
test("a stale maintenance projection during storage waits cannot authorize reload", async () => {
  let finish;
  const app=await checker({prepare:()=>new Promise(resolve=>{finish=resolve;})});
  await app.server('updating'); await app.server('available');
  app.window.utenWebServerMaintenance.updatedAt=app.now-76000;
  finish(true); await flush(); await flush();
  assert.equal(app.navigations.length,0);
  app.setPrepare(async()=>true); await app.server('available');
  assert.equal(app.navigations.length,1);
});
test("missing live maintenance state cannot authorize a version-only refresh", async () => {
  const app=await checker();
  app.window.utenWebServerMaintenance=undefined;
  app.setRemote(release('v1.1.1')); await app.online();
  assert.equal(app.navigations.length,0);
  await app.server('available'); assert.equal(app.navigations.length,1);
});
test("a page hidden during the final storage wait waits for foreground before navigation", async () => {
  let finish;
  const app=await checker({prepare:()=>new Promise(resolve=>{finish=resolve;})});
  app.setRemote(release('v1.1.1')); await app.online();
  app.document.visibilityState='hidden'; finish(true); await flush();
  assert.equal(app.navigations.length,0);
  app.setPrepare(async()=>true); app.document.visibilityState='visible';
  await app.event('visibilitychange'); assert.equal(app.navigations.length,1);
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
