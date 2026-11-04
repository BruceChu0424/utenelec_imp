/// Pure source-header identities and adjacency. Widgets and PDF workers share this model.
class UtenTableHeaderGroup {
  const UtenTableHeaderGroup({required this.id, required this.label});
  final String id, label;
  @override
  bool operator ==(Object other) =>
      other is UtenTableHeaderGroup && other.id == id && other.label == label;
  @override
  int get hashCode => Object.hash(id, label);
}

class UtenTableHeaderGroupSpan {
  const UtenTableHeaderGroupSpan({
    required this.id,
    required this.label,
    required this.columnIndices,
  });
  final String? id;
  final String label;
  final List<int> columnIndices;
}

int utenTableHeaderGroupDepth(List<List<UtenTableHeaderGroup>> columns) =>
    columns.fold<int>(0, (n, path) => n > path.length ? n : path.length);

/// Merge adjacent source IDs only. Identical captions or hidden intervening groups do not establish identity.
List<UtenTableHeaderGroupSpan> buildUtenTableHeaderGroupBand(
  List<List<UtenTableHeaderGroup>> columns,
  List<int> visibleIndices,
  int level,
) {
  if (level < 0 || visibleIndices.any((i) => i < 0 || i >= columns.length)) {
    throw const FormatException('原分组表头与字段位置不一致');
  }
  final result = <UtenTableHeaderGroupSpan>[];
  for (int at = 0; at < visibleIndices.length;) {
    final path = columns[visibleIndices[at]];
    final group = level < path.length ? path[level] : null;
    if (group != null && group.id.trim().isEmpty) {
      throw const FormatException('原分组表头缺少来源编号');
    }
    var end = at;
    while (group != null && end + 1 < visibleIndices.length) {
      final next = columns[visibleIndices[end + 1]];
      if (next.length <= level || next[level].id != group.id) break;
      if (next[level].label != group.label) {
        throw const FormatException('同一原分组表头编号对应了不同名称');
      }
      end++;
    }
    result.add(
      UtenTableHeaderGroupSpan(
        id: group?.id,
        label: group?.label ?? '',
        columnIndices: List.unmodifiable(visibleIndices.sublist(at, end + 1)),
      ),
    );
    at = end + 1;
  }
  return List.unmodifiable(result);
}
