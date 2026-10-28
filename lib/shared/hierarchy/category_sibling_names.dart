/// Checks the complete projected tree, including roots inside a virtual root.
/// Saving still validates against current server data under its hierarchy lock.
bool hasDuplicateSiblingName<T>({
  required Iterable<T> roots,
  required Iterable<T> Function(T) childrenOf,
  required String Function(T) idOf,
  required String? Function(T) parentIdOf,
  required String Function(T) nameOf,
  required String name,
  required String? parentId,
  String? excludingId,
}) {
  final normalized = name.trim();
  if (normalized.isEmpty) return false;
  for (final node in roots) {
    if (idOf(node) != excludingId &&
        parentIdOf(node) == parentId &&
        nameOf(node).trim() == normalized) {
      return true;
    }
    if (hasDuplicateSiblingName(
      roots: childrenOf(node),
      childrenOf: childrenOf,
      idOf: idOf,
      parentIdOf: parentIdOf,
      nameOf: nameOf,
      name: normalized,
      parentId: parentId,
      excludingId: excludingId,
    )) {
      return true;
    }
  }
  return false;
}
