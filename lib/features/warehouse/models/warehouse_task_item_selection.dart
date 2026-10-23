/// A null scope deliberately means the whole source document. An explicit scope
/// must never fall back to the whole document when a row is stale or missing.
class WarehouseTaskItemSelection {
  WarehouseTaskItemSelection(List<String>? itemIds)
    : itemIds = itemIds == null ? null : List.unmodifiable(itemIds);

  final List<String>? itemIds;

  bool contains(String? itemId) =>
      itemIds == null || (itemId != null && itemIds!.contains(itemId));

  Map<String, String> get queryParameters => {
    if (itemIds != null) 'itemIds': (itemIds!.toList()..sort()).join(','),
  };

  void validate(Iterable<String?> availableItemIds) {
    final selected = itemIds;
    if (selected == null) return;
    final available = availableItemIds.whereType<String>().toSet();
    if (selected.isEmpty ||
        selected.length > 500 ||
        selected.any((id) => id.trim().isEmpty) ||
        selected.toSet().length != selected.length ||
        !available.containsAll(selected)) {
      throw const FormatException('所选明细已变化，请返回任务中心刷新后重新选择');
    }
  }
}
