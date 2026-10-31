/// UUID order from the source table, frozen when opening a detail page.
/// Codes/names are display values and never identify a record.
class GoodsDetailSequence {
  GoodsDetailSequence(Iterable<String> ids, {this.label = '当前页结果'})
    : ids = List.unmodifiable(ids.where((id) => id.isNotEmpty).toSet());

  final List<String> ids;
  final String label;

  Map<String, Object> toJson() => {
    'kind': 'goods-detail-sequence-v1',
    'ids': ids,
    'label': label,
  };

  static GoodsDetailSequence? fromExtra(Object? extra) {
    if (extra is GoodsDetailSequence) return extra;
    if (extra is! Map ||
        extra['kind'] != 'goods-detail-sequence-v1' ||
        extra['ids'] is! List ||
        extra['label'] is! String) {
      return null;
    }
    final ids = extra['ids'] as List;
    if (ids.any((id) => id is! String)) return null;
    return GoodsDetailSequence(
      ids.cast<String>(),
      label: extra['label'] as String,
    );
  }
}
