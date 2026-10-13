import '../models/uten_tree_node.dart';

/// A visible path is derived from stable IDs, never from a potentially duplicated
/// category or department name. Hidden/permission-filtered nodes cannot appear.
String? utenTreeSelectionPath<T extends UtenTreeNode<T>>(
  List<T> nodes,
  String? selectedId,
) {
  if (selectedId == null) return null;
  String? visit(List<T> items, List<String> path) {
    for (final node in items) {
      final next = [...path, node.name];
      if (node.id == selectedId) return next.join(' / ');
      final found = visit(node.children, next);
      if (found != null) return found;
    }
    return null;
  }

  return visit(nodes, const []);
}
