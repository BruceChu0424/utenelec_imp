import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/master_name_provider.dart';

/// 选仓用途(ADR-146, 与服务端 WarehouseUse 同名同义)。所有仓库下拉/侧滑面板都按用途过滤,
/// 不再各页自己推算; 能不能选只认服务端字典算好的两个标记:
/// [WarehouseDictEntry.selectableForNew](启用的良品子仓) 与
/// [WarehouseDictEntry.selectableDefective](启用的不良品子仓)。
enum WarehouseUse {
  /// 良品入库: 采购/到货/产成品登记与点收/其它入库/余料退库/退货良品释放/货品所属仓库。
  goodIn,

  /// 良品出库: 生产领料/内料仓发料/委外发料/销售与客户发货/产成品出仓。
  goodOut,

  /// 转入不良品仓: 「转不良品仓」的调入仓。
  defectiveIn,

  /// 从不良品仓转出: 「不良复判转回」的调出仓。
  defectiveOut,

  /// 处置出库: 报废/其它出库/采购退货/委外成品退回, 良品仓和不良品仓都可以。
  disposalOut,

  /// 普通调拨两端: 两类都可以, 但两端必须同类(调入仓用 [WarehouseSelection.sameClassAs] 收窄)。
  transfer,

  /// 盘点: 两类都可以。
  count,

  /// 查询(看库存/流水/货架): 任何层级都可选(主仓 = 自身 + 全部子仓聚合), 默认不列已停用的仓。
  query;

  /// 只能选良品仓的用途。
  bool get goodOnly => this == goodIn || this == goodOut;

  /// 只能选不良品仓的用途。
  bool get defectiveOnly => this == defectiveIn || this == defectiveOut;
}

/// 一个用途下可以点选的仓([selectableIds])与要显示的仓([visibleIds] = 可选仓 + 它们的上级,
/// 上级只作导航/分组标题)。良品用途下不良品仓也显示出来(带「不良品」标签、置灰不可选),
/// 让人知道它存在但这里不能用。
class WarehouseSelection {
  WarehouseSelection(
    List<WarehouseDictEntry> hierarchy, {
    required this.use,
    this.sameClassAs,
  }) {
    final byId = {for (final entry in hierarchy) entry.id: entry};
    final anchor = sameClassAs == null ? null : byId[sameClassAs];
    for (final entry in hierarchy) {
      final selectable = _selectable(entry, anchor);
      final shownAsBlocked =
          !selectable &&
          use.goodOnly &&
          entry.isDefective &&
          entry.selectableDefective;
      if (!selectable && !shownAsBlocked) continue;
      if (selectable) selectableIds.add(entry.id);
      final path = <String>{};
      WarehouseDictEntry? current = entry;
      while (current != null && path.add(current.id)) {
        visibleIds.add(current.id);
        final parent = current.parentId;
        current = parent == null || parent.isEmpty ? null : byId[parent];
      }
    }
  }

  final WarehouseUse use;

  /// 普通调拨的调入仓: 只列与这个调出仓同类(良品/不良品)的仓。
  final String? sameClassAs;
  final Set<String> selectableIds = {};
  final Set<String> visibleIds = {};

  bool _selectable(WarehouseDictEntry entry, WarehouseDictEntry? anchor) {
    final good = entry.selectableForNew;
    final defective = entry.selectableDefective;
    final byUse = switch (use) {
      WarehouseUse.goodIn || WarehouseUse.goodOut => good,
      WarehouseUse.defectiveIn || WarehouseUse.defectiveOut => defective,
      WarehouseUse.disposalOut ||
      WarehouseUse.transfer ||
      WarehouseUse.count => good || defective,
      WarehouseUse.query => entry.status != '禁用',
    };
    if (!byUse || anchor == null || entry.id == anchor.id) return byUse;
    return entry.isDefective == anchor.isDefective;
  }
}

/// 字典加载后按用途算好的可选集合(ADR-146)。页面要用同一份口径时直接 watch 它。
final warehouseSelectionProvider = FutureProvider.autoDispose
    .family<WarehouseSelection, WarehouseUse>((ref, use) async {
      final names = ref.watch(masterNameServiceProvider);
      await names.ensureWarehousesLoaded();
      return WarehouseSelection(names.warehouseHierarchy, use: use);
    });
