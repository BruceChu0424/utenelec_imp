{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    // Keep the generated service-worker cleanup/update path active even
    // though this project supplies a custom loader configuration.
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    // Flutter otherwise resolves missing glyphs from a public font CDN.
    // Keep the version-pinned fallback shards same-origin for strict CSP,
    // offline deployments, and deterministic rendering.
    fontFallbackBaseUrl: new URL(
      'fallback_fonts/',
      document.baseURI,
    ).toString(),
  },
});
