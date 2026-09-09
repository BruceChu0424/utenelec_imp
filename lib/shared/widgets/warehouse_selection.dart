import '../providers/master_name_provider.dart';

/// New documents choose active, accountable leaves. Historical dictionaries and
/// stock queries keep their full contents, including disabled storage locations.
class WarehouseSelection {
  WarehouseSelection(List<WarehouseDictEntry> hierarchy) {
    final byId = {for (final entry in hierarchy) entry.id: entry};
    final parents = hierarchy.map((entry) => entry.parentId).toSet();
    for (final entry in hierarchy) {
      if (!entry.isAccountable || parents.contains(entry.id)) continue;
      final path = <String>{};
      WarehouseDictEntry? current = entry;
      var valid = false;
      while (current != null && path.add(current.id)) {
        if (current.status == '禁用') break;
        final parent = current.parentId;
        if (parent == null || parent.isEmpty) {
          valid = true;
          break;
        }
        current = byId[parent];
      }
      if (valid) {
        selectableIds.add(entry.id);
        visibleIds.addAll(path);
      }
    }
  }

  final Set<String> selectableIds = {};
  final Set<String> visibleIds = {};
}
