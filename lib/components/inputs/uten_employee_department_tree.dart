import '../../features/department/models/department_node.dart';
import '../../shared/models/uten_tree_node.dart';
import 'uten_employee_picker_models.dart';

/// The organizational tree describes hierarchy only. Candidate membership is
/// always supplied by the business loader and is never expanded by this tree.
class UtenEmployeeDepartmentDirectory {
  UtenEmployeeDepartmentDirectory({
    required List<DepartmentNode> organization,
    required Iterable<UtenEmployeePickerItem> candidates,
  }) {
    final departments = <String, String>{};
    for (final candidate in candidates) {
      final key = keyOf(candidate);
      departments[key] = key == unknownDepartment
          ? '未提供部门'
          : candidate.departmentName?.trim().isNotEmpty == true
          ? candidate.departmentName!.trim()
          : '未提供部门';
    }
    final known = <String>{};
    void index(DepartmentNode node, List<String> ancestors) {
      final key = keyForId(node.id);
      known.add(key);
      final path = [...ancestors, node.name];
      _paths[key] = path.join(' / ');
      for (final child in node.children) {
        index(child, path);
      }
    }

    for (final root in organization) {
      index(root, const []);
    }

    UtenEmployeeDepartmentNode? prune(DepartmentNode node) {
      final children = [for (final child in node.children) ?prune(child)];
      final key = keyForId(node.id);
      if (!departments.containsKey(key) && children.isEmpty) return null;
      return UtenEmployeeDepartmentNode(
        id: key,
        name: node.name,
        code: node.code,
        children: children,
      );
    }

    final unmatched =
        [
          for (final entry in departments.entries)
            if (!known.contains(entry.key))
              UtenEmployeeDepartmentNode(id: entry.key, name: entry.value),
        ]..sort((a, b) {
          final byName = a.name.compareTo(b.name);
          return byName == 0 ? a.id.compareTo(b.id) : byName;
        });
    nodes = [
      const UtenEmployeeDepartmentNode(id: allDepartments, name: '全部部门'),
      for (final root in organization) ?prune(root),
      // Explicit non-org candidates (for example external audit actors) must
      // remain available, without pretending that they belong to the company.
      if (unmatched.isNotEmpty && organization.isNotEmpty)
        UtenEmployeeDepartmentNode(
          id: otherDepartments,
          name: '其它候选',
          children: unmatched,
        )
      else
        ...unmatched,
    ];

    Set<String> collect(UtenEmployeeDepartmentNode node) {
      final ids = <String>{node.id};
      for (final child in node.children) {
        ids.addAll(collect(child));
      }
      _subtrees[node.id] = ids;
      return ids;
    }

    for (final root in nodes) {
      collect(root);
    }
  }

  static const allDepartments = 'employee-picker:all';
  static const otherDepartments = 'employee-picker:other';
  static const unknownDepartment = 'employee-picker:unknown';

  late final List<UtenEmployeeDepartmentNode> nodes;
  final _paths = <String, String>{};
  final _subtrees = <String, Set<String>>{};

  static String keyForId(String id) => 'department:$id';

  static String keyOf(UtenEmployeePickerItem item) {
    final id = item.departmentId?.trim();
    return id == null || id.isEmpty ? unknownDepartment : keyForId(id);
  }

  String? pathOf(UtenEmployeePickerItem item) => _paths[keyOf(item)];

  bool contains(String scope, UtenEmployeePickerItem item) =>
      scope == allDepartments ||
      (_subtrees[scope]?.contains(keyOf(item)) ?? false);

  /// Keep matching departments and every real ancestor visible during search.
  Set<String> visibleIdsFor(Iterable<UtenEmployeePickerItem> items) {
    final matches = items.map(keyOf).toSet();
    return {
      allDepartments,
      for (final entry in _subtrees.entries)
        if (entry.value.any(matches.contains)) entry.key,
    };
  }
}

class UtenEmployeeDepartmentNode
    implements UtenTreeNode<UtenEmployeeDepartmentNode> {
  const UtenEmployeeDepartmentNode({
    required this.id,
    required this.name,
    this.code = '',
    this.children = const [],
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String code;
  @override
  final List<UtenEmployeeDepartmentNode> children;
  @override
  bool get hasChildren => children.isNotEmpty;
}
