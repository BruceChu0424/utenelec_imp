import 'package:collection/collection.dart';

/// Optional local profiling counters for the scoped complete-read ownership
/// fence, following the [debugUiWorkSliceObserver] pattern: a test or a local
/// profiling session installs one, production keeps it null and nothing is
/// counted, and no values, row identities or response contents are recorded.
ScopedReadCheckStats? debugScopedReadCheckStats;

/// Counts how often ownership was re-checked during scoped complete reads and
/// how many of those checks actually re-compared the query. The gap between
/// [ownerChecks] and [queryCompares] is the answer reuse inside one
/// event-loop turn; [loopChecks] counts the complete/cursor batch-loop
/// ownership evaluations themselves.
class ScopedReadCheckStats {
  int ownerChecks = 0;
  int queryCompares = 0;
  int epochReads = 0;
  int loopChecks = 0;

  void reset() {
    ownerChecks = 0;
    queryCompares = 0;
    epochReads = 0;
    loopChecks = 0;
  }
}

/// Copies query collections while retaining opaque repository/model identities.
/// Nested query collections use Maps/Lists, not mutable fields inside records.
Object? freezePagedReadQuery(Object? value) => switch (value) {
  Map() => Map<Object?, Object?>.unmodifiable({
    for (final entry in value.entries)
      freezePagedReadQuery(entry.key): freezePagedReadQuery(entry.value),
  }),
  Set() => Set<Object?>.unmodifiable(value.map(freezePagedReadQuery)),
  Iterable() => List<Object?>.unmodifiable(value.map(freezePagedReadQuery)),
  _ => value,
};

bool samePagedReadQuery(Object? before, Object? after) =>
    const DeepCollectionEquality().equals(before, after);

/// An immutable collection value inside a table's otherwise scalar scope.
/// Records compare their fields with ==, so fresh Maps/Lists need this value
/// boundary to avoid resetting pagination during an unrelated rebuild.
final class PagedReadQueryKey {
  PagedReadQueryKey(Object? value) : _value = freezePagedReadQuery(value);

  final Object? _value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PagedReadQueryKey && samePagedReadQuery(_value, other._value);

  @override
  int get hashCode => const DeepCollectionEquality().hash(_value);
}
