// Only response decoding: no network, credentials, persistence or logging.
// Loaded from the application origin under the existing worker-src policy.
self.onmessage = function (event) {
  const { id, bytes } = event.data;
  try {
    const text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    self.postMessage({ id, value: text.length === 0 ? null : JSON.parse(text) });
  } catch (_) {
    // Do not put response contents or parser excerpts into diagnostics.
    self.postMessage({ id, error: 'invalid-json' });
  }
};
