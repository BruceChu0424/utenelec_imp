// 订货编辑网格（UtenEditableGrid.showColumnSettings）列显隐与排序的账号级
// 持久化：宿主侧存储。状态按「单据模式 key」分桶——同一 provider 服务于一个
// 编辑页的全部模式（如销售订货/出货/退货共用一个 provider、互不覆盖），跨
// 设备/重登经 user_preferences 自动带上（三层策略见 UtenPagePrefsNotifier）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'uten_page_prefs_notifier.dart';

/// 一个模式下的列设置快照：order=完整列顺序（含隐藏列），hidden=隐藏列 key。
class EditableGridColumnsPrefs {
  const EditableGridColumnsPrefs({
    this.order = const [],
    this.hidden = const {},
  });

  final List<String> order;
  final Set<String> hidden;
}

/// 全部订货编辑页共用的基类：state = {模式key: 列设置}。页面只读写自己模式
/// 的桶，[updateFor] 替换整桶后防抖推服务端。
abstract class EditableGridColumnPrefsNotifierBase
    extends UtenPagePrefsNotifier<Map<String, EditableGridColumnsPrefs>> {
  @override
  Map<String, EditableGridColumnsPrefs> get defaultValue => const {};

  @override
  Map<String, EditableGridColumnsPrefs>? decode(Object? raw) {
    if (raw is! Map) return null;
    final result = <String, EditableGridColumnsPrefs>{};
    for (final entry in raw.entries) {
      final mode = entry.key.toString();
      final value = entry.value;
      if (value is! Map) continue;
      final order = value['order'];
      final hidden = value['hidden'];
      result[mode] = EditableGridColumnsPrefs(
        order: order is List
            ? List.unmodifiable(
                order.map((item) => item.toString()).where((s) => s.isNotEmpty),
              )
            : const [],
        hidden: hidden is List
            ? Set.unmodifiable(
                hidden
                    .map((item) => item.toString())
                    .where((s) => s.isNotEmpty),
              )
            : const {},
      );
    }
    return result;
  }

  @override
  Object? encode(Map<String, EditableGridColumnsPrefs> state) {
    return {
      for (final entry in state.entries)
        entry.key: {
          'order': entry.value.order,
          'hidden': entry.value.hidden.toList(growable: false),
        },
    };
  }

  void updateFor(String mode, List<String> order, Set<String> hidden) {
    state = {
      ...state,
      mode: EditableGridColumnsPrefs(
        order: List.unmodifiable(order),
        hidden: Set.unmodifiable(hidden),
      ),
    };
    persist();
  }
}

class SalesDocGridColumnPrefsNotifier
    extends EditableGridColumnPrefsNotifierBase {
  @override
  String get prefKey => 'sales.docEdit.gridColumns';
}

class PurchaseDocGridColumnPrefsNotifier
    extends EditableGridColumnPrefsNotifierBase {
  @override
  String get prefKey => 'purchase.doc.gridColumns';
}

class PurchaseOrderGridColumnPrefsNotifier
    extends EditableGridColumnPrefsNotifierBase {
  @override
  String get prefKey => 'purchase.order.gridColumns';
}

class SubcontractApplicationGridColumnPrefsNotifier
    extends EditableGridColumnPrefsNotifierBase {
  @override
  String get prefKey => 'subcontract.application.gridColumns';
}

class SubcontractOrderGridColumnPrefsNotifier
    extends EditableGridColumnPrefsNotifierBase {
  @override
  String get prefKey => 'subcontract.order.gridColumns';
}

final salesDocGridColumnPrefsProvider =
    NotifierProvider<
      SalesDocGridColumnPrefsNotifier,
      Map<String, EditableGridColumnsPrefs>
    >(SalesDocGridColumnPrefsNotifier.new);

final purchaseDocGridColumnPrefsProvider =
    NotifierProvider<
      PurchaseDocGridColumnPrefsNotifier,
      Map<String, EditableGridColumnsPrefs>
    >(PurchaseDocGridColumnPrefsNotifier.new);

final purchaseOrderGridColumnPrefsProvider =
    NotifierProvider<
      PurchaseOrderGridColumnPrefsNotifier,
      Map<String, EditableGridColumnsPrefs>
    >(PurchaseOrderGridColumnPrefsNotifier.new);

final subcontractApplicationGridColumnPrefsProvider =
    NotifierProvider<
      SubcontractApplicationGridColumnPrefsNotifier,
      Map<String, EditableGridColumnsPrefs>
    >(SubcontractApplicationGridColumnPrefsNotifier.new);

final subcontractOrderGridColumnPrefsProvider =
    NotifierProvider<
      SubcontractOrderGridColumnPrefsNotifier,
      Map<String, EditableGridColumnsPrefs>
    >(SubcontractOrderGridColumnPrefsNotifier.new);
