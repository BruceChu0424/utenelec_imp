import 'post_evidence_stub.dart'
    if (dart.library.js_interop) 'post_evidence_web.dart'
    as platform;

/// Synthetic diagnostic metrics only. This has no business API fallback and
/// always omits ambient cookies in the dedicated loopback browser fixture.
Future<void> postB1HarnessEvidence(Map<String, Object?> result) =>
    platform.postB1HarnessEvidence(result);
