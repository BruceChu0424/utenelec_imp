// 服务端表头值筛选+排序的页面侧共享状态（2026-09-25 单号列统一批次收口）。
// 各列表页此前各自手写「值 Map + 桶 Map + 排序两字段 + facets 代数」四件套，
// 这里一份实现全站复用；页面只保留「列 key → 重拉参数」的映射与排序白名单。
import 'package:flutter/foundation.dart';

import '../models/master_facet.dart';

/// 服务端表头列筛选/排序的页面侧共享状态（2026-09-25 单号列统一）。
///
/// 页面只声明「列 key → 重拉参数」映射；值、桶、排序态、防竞态代数都在这里。
/// 用法：页面 State 持有一个实例，reload 时调 [loadFacets]；表格的
/// facets/filters/sortColumn/onSortChange/onFilterChanged 全部转发给它：
///
/// ```dart
/// final _columnFilters = MasterServerColumnFilters();
///
/// /// 单号桶随过滤上下文重取（失败静默保持旧桶，不阻断列表）。
/// Future<void> _loadBillNoFacets() => _columnFilters.loadFacets(
///   () async => {'billNo': await repo.billNoFacets(filter: _filter())},
///   onLoaded: () {
///     if (mounted) setState(() {});
///   },
/// );
///
/// MasterDataTableView(
///   facets: {'billNo': _columnFilters.bucketOf('billNo')},
///   filters: {'billNo': _columnFilters['billNo']},
///   sortColumn: _columnFilters.sortColumn,
///   sortAscending: _columnFilters.sortAscending,
///   onFilterChanged: (key, value) => _columnFilters.handleFilterChanged(
///     key,
///     value,
///     onChanged: () => _reload(1), // 页面自己的 setState + 重拉
///   ),
///   onSortChange: _onSortChange,
/// );
/// ```
///
/// 约定：
/// - [setValue] 里 null/空串 = 清除该列筛选；[values]/`instance[key]` 取 null
///   表示该列不筛（与各仓库「空串等价不过滤」的参数口径一致）。
/// - [loadFacets] 代数防串台（过期响应不落地）+ 静默失败（旧桶保留，下拉只是
///   缺新值，不阻断列表）；[onLoaded] 即页面的 setState（含 mounted 检查）。
/// - 排序列为 null 时 [sortAscending] 归一为 true（取消排序回服务端默认序）；
///   排序白名单（列 key → 服务端 sort 参数）仍是页面自己的事——宿主先校验/
///   映射，再调 [handleSortChanged]。
/// - [reset] 清值 + 清桶 + 清排序（分段/类别切换整体回默认）；只清值不清排序
///   用 [clearValues]。
class MasterServerColumnFilters {
  /// 列 key → 当前筛选值（null = 不筛；空串已归一为移除）。
  final Map<String, String?> values = {};

  /// 列 key → 服务端分组计数桶（facets 端点最近一次成功结果；空表 = 尚未
  /// 返回或加载失败）。
  Map<String, List<MasterFacetBucket>> buckets = const {};

  /// 当前排序列 key；null = 服务端默认序。排序列归页面或本类皆可（单据列表
  /// 页排序常驻 PagedListController，本类字段供自持排序的工作台/分段页用）。
  String? sortColumn;

  /// 当前排序方向：true=升序，false=降序。仅当 [sortColumn] 非空时有意义。
  bool sortAscending = true;

  /// facets 请求代数：过期响应不再落地（与列表请求版本号同款防串台）。
  int generation = 0;

  /// 该列当前筛选值；null = 不筛。
  String? operator [](String key) => values[key];

  /// 该列的 facets 桶；未加载/加载失败返回空表。
  List<MasterFacetBucket> bucketOf(String key) => buckets[key] ?? const [];

  /// [key] 列是否当前排序列（表头排序箭头态）。
  bool sortActive(String key) => sortColumn == key;

  /// 设置某列筛选值：null/空串 → 移除（等价不筛）。
  void setValue(String key, String? v) {
    if (v == null || v.isEmpty) {
      values.remove(key);
    } else {
      values[key] = v;
    }
  }

  /// 清空全部列筛选值（桶与排序保持；整体回默认用 [reset]）。
  void clearValues() => values.clear();

  /// 整体回默认：清值 + 清桶 + 清排序。分段/类别切换时调用。
  void reset() {
    values.clear();
    buckets = const {};
    sortColumn = null;
    sortAscending = true;
  }

  /// 重取 facets：代数防串台 + 静默失败（保持旧桶，不阻断列表）。
  /// [fetch] 返回「列 key → 桶」；[onLoaded] 在成功落地后同步回调，页面在这里
  /// setState（自行带 mounted 检查）。
  Future<void> loadFacets(
    Future<Map<String, List<MasterFacetBucket>>> Function() fetch, {
    required VoidCallback onLoaded,
  }) async {
    final gen = ++generation;
    try {
      final result = await fetch();
      if (gen != generation) return;
      buckets = result;
      onLoaded();
    } catch (_) {
      // 静默：桶缺失只是下拉为空，列表不受影响。
    }
  }

  /// 表头筛选回调：记录值后交 [onChanged]（页面 setState + 重拉回第 1 页）。
  void handleFilterChanged(
    String key,
    String? value, {
    required VoidCallback onChanged,
  }) {
    setValue(key, value);
    onChanged();
  }

  /// 表头排序回调：更新排序态后交 [onChanged]（页面 setState + 重拉回第 1 页）。
  /// column 为 null 时方向归一为升序（取消排序回服务端默认序）。
  void handleSortChanged(
    String? column,
    bool ascending, {
    required VoidCallback onChanged,
  }) {
    sortColumn = column;
    sortAscending = column == null ? true : ascending;
    onChanged();
  }
}
