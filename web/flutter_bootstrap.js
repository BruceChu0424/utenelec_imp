{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    // Keep the generated service-worker cleanup/update path active even
    // though this project supplies a custom loader configuration.
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    // Flutter 3.44.2's automatic selection uses the Chromium-optimized
    // CanvasKit build when Chrome exposes ImageDecoder and V8 break iterators.
    // That build has reproduced a synchronous WASM renderer hang in this app.
    // Pin the universal build as a narrow, reversible mitigation; removing this
    // option restores Flutter's default automatic selection.
    canvasKitVariant: 'full',
    // Flutter otherwise resolves missing glyphs from a public font CDN.
    // Keep the version-pinned fallback shards same-origin for strict CSP,
    // offline deployments, and deterministic rendering.
    fontFallbackBaseUrl: new URL(
      'fallback_fonts/',
      document.baseURI,
    ).toString(),
  },
});
