import 'package:collection/collection.dart';

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
