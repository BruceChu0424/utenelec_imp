/// Builds a short, deterministic idempotency key for one user-visible action.
///
/// Callers should include the document's current persisted counters and the
/// requested delta in [canonicalPayload]. A retry after a lost response then
/// reuses the same key, while the next legitimate partial operation receives a
/// different key because its persisted counters have changed.
String businessIdempotencyKey(String action, String canonicalPayload) {
  // Keep every intermediate below JavaScript's exact-integer ceiling. Two
  // independent 31-bit polynomial hashes retain a bounded 62-bit fingerprint
  // without relying on VM-only 64-bit integer literals.
  const modulus = 0x80000000;
  var primary = 0x1e35a7bd;
  var secondary = 0x0f4c3b2a;
  for (final codeUnit in canonicalPayload.codeUnits) {
    primary = (primary * 33 + codeUnit) % modulus;
    secondary = (secondary * 65599 + codeUnit) % modulus;
  }
  final fingerprint =
      '${primary.toRadixString(16).padLeft(8, '0')}'
      '${secondary.toRadixString(16).padLeft(8, '0')}';
  return '$action-$fingerprint';
}
