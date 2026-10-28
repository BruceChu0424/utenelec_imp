/// Presentation state for data trees that start collapsed. New branches start
/// closed; refreshing the same identities preserves every manual decision.
/// Call [reset] when changing the owning document or dataset.
class UtenDefaultCollapsedTreeState {
  final Set<String> collapsedIds = {};
  final Set<String> _knownIds = {};

  void reconcile(Iterable<String> branchIds) {
    final current = branchIds.toSet();
    collapsedIds
      ..retainAll(current)
      ..addAll(current.difference(_knownIds));
    _knownIds
      ..clear()
      ..addAll(current);
  }

  void reset() {
    collapsedIds.clear();
    _knownIds.clear();
  }
}
