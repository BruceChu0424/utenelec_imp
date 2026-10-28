/// Keep complete groups from an already projected preorder view. This never
/// expands collapsed nodes, invents parents, reorders source rows or mutates them.
/// Callers define a real group boundary (product, BOM root or material group).
List<T> retainMatchedPreorderGroups<T>(
  List<T> all,
  List<T> matched, {
  required bool Function(T row) isGroupStart,
}) {
  if (matched.isEmpty) return <T>[];
  if (matched.length == all.length) return all;
  final matches = Set<T>.identity()..addAll(matched);
  final result = <T>[];
  var group = <T>[];
  var keep = false;
  void flush() {
    if (keep) result.addAll(group);
    group = <T>[];
    keep = false;
  }

  for (final row in all) {
    if (group.isNotEmpty && isGroupStart(row)) flush();
    group.add(row);
    keep = keep || matches.contains(row);
  }
  flush();
  return result;
}

/// Retain only matching rows and their already visible ancestors. Collapsed
/// descendants are never loaded or invented, and source preorder is unchanged.
List<T> retainMatchedPreorderAncestors<T>(
  List<T> all,
  List<T> matched, {
  required int Function(T row) depthOf,
}) {
  if (matched.isEmpty) return <T>[];
  if (matched.length == all.length) return all;
  final matches = Set<T>.identity()..addAll(matched);
  final retained = Set<T>.identity();
  final ancestors = <({T row, int depth})>[];
  for (final row in all) {
    final depth = depthOf(row);
    while (ancestors.isNotEmpty && ancestors.last.depth >= depth) {
      ancestors.removeLast();
    }
    if (matches.contains(row)) {
      retained.add(row);
      retained.addAll(ancestors.map((entry) => entry.row));
    }
    ancestors.add((row: row, depth: depth));
  }
  return all.where(retained.contains).toList(growable: false);
}
