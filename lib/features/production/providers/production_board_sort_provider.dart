// 生产调度与进度看板：进行中/已完成列表排序方式偏好（按账号持久化）。
//
// 值域 = production_board_page 的 _PlanSort.name：
//   billDate（开单远→近，默认）/ billDateDesc（开单近→远）/ deliveryDate / progress
// 走 UtenPagePrefsNotifier 三层策略：本地缓存即时渲染 → 登录后服务端同步 → 写路径防抖推送。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

class ProductionBoardSortNotifier extends UtenPagePrefsNotifier<String> {
  static const values = {
    'billDate',
    'billDateDesc',
    'deliveryDate',
    'progress',
  };

  @override
  String get prefKey => 'productionBoard.sort';

  @override
  String get defaultValue => 'billDate';

  @override
  String? decode(Object? raw) =>
      raw is String && values.contains(raw) ? raw : null;

  @override
  Object? encode(String state) => state;
}

/// 看板排序方式（进行中/已完成两 Tab 共用一份偏好）。
final productionBoardSortProvider =
    NotifierProvider<ProductionBoardSortNotifier, String>(
      ProductionBoardSortNotifier.new,
    );
