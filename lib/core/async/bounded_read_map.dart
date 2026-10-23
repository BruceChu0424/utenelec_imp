/// A read batch lost its caller's lifetime, query or reader identity.
/// Already started reads are observed, but their results must not be published.
class BoundedReadSuperseded implements Exception {
  const BoundedReadSuperseded();
}

/// Reads a frozen input sequence with a shared concurrency bound, preserving
/// input order even when responses complete out of order.
///
/// Only use this for independent reads. It does not retry or cancel a transport,
/// and must never schedule business writes. After the first failure or a false
/// [isCurrent], no more reads start. All started futures remain observed.
Future<List<R>> boundedReadMap<T, R>(
  Iterable<T> inputs,
  Future<R> Function(T input) read, {
  int maxConcurrent = 4,
  bool Function()? isCurrent,
}) async {
  if (maxConcurrent < 1) {
    throw ArgumentError.value(
      maxConcurrent,
      'maxConcurrent',
      'must be positive',
    );
  }
  final items = List<T>.of(inputs, growable: false);
  final results = List<Object?>.filled(items.length, null);
  var next = 0;
  var stopped = false;

  void checkCurrent() {
    if (isCurrent != null && !isCurrent()) {
      throw const BoundedReadSuperseded();
    }
  }

  Future<void> worker() async {
    try {
      while (!stopped && next < items.length) {
        checkCurrent();
        final index = next++;
        final result = await read(items[index]);
        checkCurrent();
        results[index] = result;
      }
    } catch (_) {
      stopped = true;
      rethrow;
    }
  }

  checkCurrent();
  await Future.wait([
    for (var i = 0; i < maxConcurrent && i < items.length; i++) worker(),
  ], eagerError: true);
  checkCurrent();
  return List<R>.generate(items.length, (index) => results[index] as R);
}
