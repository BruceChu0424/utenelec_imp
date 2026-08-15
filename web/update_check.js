(() => {
  "use strict";

  const CHECK_INTERVAL_MS = 60_000;
  const BANNER_ID = "uten-web-update-banner";
  const DISMISS_KEY = "uten-web-update-dismissed";
  const VERSION_RE = /^v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}$/;
  const COMMIT_RE = /^[0-9a-f]{40}$/;
  const baselineVersion = document
    .querySelector('meta[name="uten-release-version"]')
    ?.getAttribute("content")
    ?.trim();
  let announcedVersion;
  let checkInFlight = false;

  function versionUrl() {
    const url = new URL("version.json", document.baseURI);
    url.searchParams.set("uten-update-check", Date.now().toString());
    return url;
  }

  function isReleaseMetadata(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const keys = Object.keys(value).sort();
    if (keys.join(",") !== "commitSha,product,releaseSequence,schemaVersion,version") return false;
    return value.schemaVersion === 1
      && value.product === "uten-imp"
      && typeof value.version === "string"
      && VERSION_RE.test(value.version)
      && Number.isSafeInteger(value.releaseSequence)
      && value.releaseSequence > 0
      && typeof value.commitSha === "string"
      && COMMIT_RE.test(value.commitSha);
  }

  function dismissedVersion() {
    try {
      return window.sessionStorage.getItem(DISMISS_KEY);
    } catch {
      return null;
    }
  }

  function rememberDismissal(value) {
    try {
      window.sessionStorage.setItem(DISMISS_KEY, value);
    } catch {
      // A blocked storage API must not prevent dismissal for this page view.
    }
  }

  function removeBanner() {
    document.getElementById(BANNER_ID)?.remove();
    announcedVersion = undefined;
  }

  function showUpdate(nextVersion) {
    if (dismissedVersion() === nextVersion) return;
    if (announcedVersion === nextVersion) return;

    removeBanner();
    announcedVersion = nextVersion;

    const region = document.createElement("aside");
    region.id = BANNER_ID;
    region.setAttribute("role", "status");
    region.setAttribute("aria-live", "polite");
    region.setAttribute("aria-atomic", "true");
    region.setAttribute("aria-label", "系统更新提示");

    const copy = document.createElement("div");
    copy.className = "uten-web-update-copy";

    const title = document.createElement("strong");
    title.textContent = "发现新版本";

    const message = document.createElement("span");
    message.textContent = "请先保存正在编辑的内容，再刷新页面。系统不会自动刷新。";

    const actions = document.createElement("div");
    actions.className = "uten-web-update-actions";

    const later = document.createElement("button");
    later.type = "button";
    later.className = "uten-web-update-secondary";
    later.textContent = "稍后";
    later.addEventListener("click", () => {
      rememberDismissal(nextVersion);
      removeBanner();
    });

    const refresh = document.createElement("button");
    refresh.type = "button";
    refresh.className = "uten-web-update-primary";
    refresh.textContent = "我已保存，刷新";
    refresh.addEventListener("click", () => {
      refresh.disabled = true;
      refresh.textContent = "正在刷新…";
      window.setTimeout(() => {
        refresh.disabled = false;
        refresh.textContent = "我已保存，刷新";
      }, 2_000);
      window.location.reload();
    });

    copy.append(title, message);
    actions.append(later, refresh);
    region.append(copy, actions);
    document.body.append(region);
  }

  async function checkForUpdate() {
    // Local/dev builds retain the token and intentionally do not poll. Every
    // production build must be stamped by the fail-closed release helper.
    if (!baselineVersion || !VERSION_RE.test(baselineVersion)) return;
    if (checkInFlight || document.visibilityState === "hidden") return;
    checkInFlight = true;
    try {
      const response = await fetch(versionUrl(), {
        cache: "no-store",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Cache-Control": "no-cache",
        },
      });
      if (!response.ok) return;

      const metadata = await response.json();
      if (!isReleaseMetadata(metadata)) return;
      if (metadata.version === baselineVersion) {
        removeBanner();
        return;
      }
      showUpdate(metadata.version);
    } catch {
      // Update checks are advisory. Connectivity handling remains in Flutter.
    } finally {
      checkInFlight = false;
    }
  }

  void checkForUpdate();
  window.setInterval(checkForUpdate, CHECK_INTERVAL_MS);
  window.addEventListener("online", checkForUpdate);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void checkForUpdate();
  });
})();
