/// Detaches maps/lists immediately without scanning immutable string contents.
/// Non-container atoms are shared; callers must only supply immutable atoms
/// (including the deferred binary handles used by the draft writer).
Object? snapshotJsonValue(Object? value) => JsonValueSnapshot._copy(value);

bool jsonValuesEqual(Object? left, Object? right) =>
    JsonValueSnapshot._equal(left, right);

/// An immediate detached snapshot of JSON containers. Large immutable strings
/// (for example an already encoded attachment) are retained without scanning or
/// re-encoding their bytes. This is a local change guard, not a wire codec/hash.
class JsonValueSnapshot {
  JsonValueSnapshot.capture(Map<String, dynamic> value)
    : data = _copy(value) as Map<String, dynamic>;

  final Map<String, dynamic> data;

  bool matches(Map<String, dynamic> value) => _equal(data, value);

  static Object? _copy(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries) entry.key: _copy(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_copy));
    }
    return value;
  }

  static bool _equal(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map<String, dynamic> && right is Map<String, dynamic>) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_equal(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_equal(left[i], right[i])) return false;
      }
      return true;
    }
    // Keep numeric JSON spellings distinct, just as the previous encoded
    // checkpoint did (including negative zero). Raw numeric input stays text.
    if (left is num && right is num) {
      return left.runtimeType == right.runtimeType &&
          left.toString() == right.toString();
    }
    return left == right;
  }
}
