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
