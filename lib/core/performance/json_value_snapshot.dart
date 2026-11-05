import 'ui_work_budget.dart';

/// Detaches maps/lists immediately without scanning immutable string contents.
/// Non-container atoms are shared; callers must only supply immutable atoms
/// (including the deferred binary handles used by the draft writer).
Object? snapshotJsonValue(Object? value) => JsonValueSnapshot._copy(value);

bool jsonValuesEqual(Object? left, Object? right) =>
    JsonValueSnapshot._equal(left, right);

/// Same detached JSON contract as the synchronous helper, with bounded work
/// for large original commands. Strings and immutable atoms stay untouched.
Future<Object?> snapshotJsonValueResponsive(
  Object? value, {
  bool Function()? isCurrent,
}) async {
  final work = UiWorkBudget(isCurrent: isCurrent, debugLabel: 'json-snapshot');
  Future<Object?> copy(Object? item) async {
    await work.checkpoint();
    if (item is Map<String, dynamic>) {
      final result = <String, dynamic>{};
      for (final entry in item.entries) {
        result[entry.key] = await copy(entry.value);
      }
      return Map<String, dynamic>.unmodifiable(result);
    }
    if (item is List) {
      final result = <Object?>[];
      for (final child in item) {
        result.add(await copy(child));
      }
      return List<Object?>.unmodifiable(result);
    }
    return item;
  }

  final result = await copy(value);
  work.ensureCurrent();
  return result;
}

/// Does not serialize, normalize numeric spellings or publish partial proof.
/// Both operands must remain owned by the caller until this read completes.
Future<bool> jsonValuesEqualResponsive(
  Object? left,
  Object? right, {
  bool Function()? isCurrent,
}) async {
  final work = UiWorkBudget(isCurrent: isCurrent, debugLabel: 'json-equality');
  final pending = <(Object?, Object?)>[(left, right)];
  while (pending.isNotEmpty) {
    await work.checkpoint();
    final pair = pending.removeLast(), first = pair.$1, second = pair.$2;
    if (identical(first, second)) continue;
    if (first is Map<String, dynamic> && second is Map<String, dynamic>) {
      if (first.length != second.length) return false;
      for (final entry in first.entries) {
        if (!second.containsKey(entry.key)) return false;
        pending.add((entry.value, second[entry.key]));
        await work.checkpoint();
      }
    } else if (first is List && second is List) {
      if (first.length != second.length) return false;
      for (var index = 0; index < first.length; index++) {
        pending.add((first[index], second[index]));
        await work.checkpoint();
      }
    } else if (!JsonValueSnapshot._equal(first, second)) {
      return false;
    }
  }
  work.ensureCurrent();
  return true;
}

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
