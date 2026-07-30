// 生产计划单明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// ProductionGridRow：产品编号/货品(选择)/排产量/订货量/颜色/单位/关联销售订单号/备注。
// 生产计划无金额（数量驱动）：qtyNotifier 作表尾合计源（重写 amountValue/listenAmount），
// 底栏 ValueListenableBuilder 订阅 grid.totalListenable 显示「排产合计」（镜像销售金额合计范式）。
// 颜色/单位选货品后自动回填（MasterNameService 桥 legacy→UUID），单元格只读显示。
// productionGridColumns：与 salesGridColumns 同形（货品点选 / 颜色单位只读 / 数量 numeric）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';

/// 生产计划明细行。货品用 ValueNotifier（点选后单元格自动刷新，无需 setState）；
/// 排产量控制器变更 → 写回 qtyNotifier（表尾合计订阅它）。
/// 颜色/单位为透传（选货品后自动回填，保存时随行写回，单元格只读显示）。
class ProductionGridRow extends EditableGridRow {
  ProductionGridRow() {
    qty.addListener(_recalc);
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(null);
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController productNo = TextEditingController();
  final TextEditingController qty = TextEditingController();
  final TextEditingController oqty = TextEditingController();
  final TextEditingController salesOrderNo = TextEditingController();
  final TextEditingController remark = TextEditingController();

  /// 业务链溯源（从订单带明细时回填；保存随 salesOrderItemId 提交，
  /// 计划审核时按 1:1 link 回写 sales_order_items.planned_qty）。
  String? salesOrderItemId;
  String? clientName;
  double? unitRate; // 单位换算率（订单行带出；MRP 毛需求按基本单位折算依赖它）
  String? orderDate; // yyyy-MM-dd（订单日期）
  String? outboundDate; // yyyy-MM-dd（交货日）

  /// 颜色/单位（选货品后自动回填；单元格只读显示）。ValueNotifier 即时刷新。
  final colorIdNotifier = ValueNotifier<String?>(null);
  String? get colorId => colorIdNotifier.value;
  set colorId(String? v) => colorIdNotifier.value = v;
  final unitIdNotifier = ValueNotifier<String?>(null);
  String? get unitId => unitIdNotifier.value;
  set unitId(String? v) => unitIdNotifier.value = v;

  /// 排产量合计源：qty 变化 → qtyNotifier；表尾合计订阅它（复用 grid.totalListenable）。
  final ValueNotifier<double> qtyNotifier = ValueNotifier<double>(0);

  @override
  double get amountValue => qtyNotifier.value;

  @override
  VoidCallback listenAmount(VoidCallback cb) {
    qtyNotifier.addListener(cb);
    return () => qtyNotifier.removeListener(cb);
  }

  void _recalc() {
    final v = double.tryParse(qty.text) ?? 0;
    if (v != qtyNotifier.value) qtyNotifier.value = v;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    qtyNotifier.dispose();
    productNo.dispose();
    qty.dispose();
    oqty.dispose();
    salesOrderNo.dispose();
    remark.dispose();
    super.dispose();
  }
}

/// 生产明细列：产品编号 / 货品（点选）/ 颜色（只读）/ 单位（只读）/ 排产量 / 订货量 /
/// 关联销售订单号 / 备注。[onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）；
/// [colorEntries]/[unitEntries] 由编辑页从 masterNameServiceProvider 注入（只读单元格显示名）。
List<EditableGridColumn<ProductionGridRow>> productionGridColumns({
  required Future<void> Function(ProductionGridRow row) onPickGoods,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
}) {
  return [
    EditableGridColumn<ProductionGridRow>(
      key: 'productNo',
      label: '产品编号',
      width: 120,
      cellBuilder: (context, row) => TextField(
        controller: row.productNo,
        decoration: const InputDecoration(isDense: true, hintText: '必填'),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      cellBuilder: (context, row) => InkWell(
        onTap: () => onPickGoods(row),
        child: InputDecorator(
          decoration: const InputDecoration(isDense: true),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<GoodsOption?>(
                  valueListenable: row.goodsNotifier,
                  builder: (context, g, _) => Text(
                    g?.name ?? '点击选择',
                    style: TextStyle(
                      color: g == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const Icon(Icons.search_rounded, size: 16),
            ],
          ),
        ),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'qty',
      label: '排产量',
      width: 96,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.qty,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'oqty',
      label: '订货量',
      width: 96,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.oqty,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'salesOrderNo',
      label: '关联销售订单号',
      width: 150,
      cellBuilder: (context, row) => TextField(
        controller: row.salesOrderNo,
        decoration: const InputDecoration(isDense: true, hintText: '可选'),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
  ];
}

/// 只读主档字段单元格（颜色/单位自动回填后用）：显示 entries[id] 名，空显示「—」。
Widget _readOnlyMasterCell(
  BuildContext context,
  ValueNotifier<String?> notifier,
  Map<String, String> entries,
) {
  final theme = Theme.of(context);
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, id, _) {
      final name = (id != null && id.isNotEmpty) ? entries[id] : null;
      final hasName = name != null && name.isNotEmpty;
      return Text(
        hasName ? name : '—',
        style:
            TextStyle(color: hasName ? null : theme.colorScheme.onSurfaceVariant),
      );
    },
  );
}
