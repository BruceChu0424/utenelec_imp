// 生产计划单明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// ProductionGridRow：产品编号/货品(选择)/排产量/订货量/颜色/关联销售订单号/备注。
// 生产计划无金额（数量驱动）：qtyNotifier 作表尾合计源（重写 amountValue/listenAmount），
// 底栏 ValueListenableBuilder 订阅 grid.totalListenable 显示「排产合计」（镜像销售金额合计范式）。
// 颜色选货品后直接回填货品主档 UUID；编号/名称只作只读显示，不做 legacy→UUID 反查。
// 2026-10-10 用户口径（全站表格数量口径）：独立「单位」列撤销，单位作为排产量/
// 订货量输入框的后缀（suffixText）随行回填的 unitId 即时刷新。
// productionGridColumns：与 salesGridColumns 同形（货品点选 / 颜色只读 / 数量 numeric）。
import 'package:flutter/material.dart';
import 'production_overproduction_rate_field.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';

/// 生产计划明细行。货品用 ValueNotifier（点选后单元格自动刷新，无需 setState）；
/// 排产量控制器变更 → 写回 qtyNotifier（表尾合计订阅它）。
/// 颜色/单位为透传（选货品后自动回填，保存时随行写回；颜色单元格只读显示，
/// 单位作排产量/订货量输入框后缀）。
class ProductionGridRow extends EditableGridRow {
  ProductionGridRow() {
    qty.addListener(_recalc);
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController productNo = TextEditingController();
  final TextEditingController qty = TextEditingController();
  final TextEditingController overproductionPercent = TextEditingController(
    text: '0',
  );
  int overproductionDefaultRequestVersion = 0;
  final TextEditingController oqty = TextEditingController();
  final TextEditingController salesOrderNo = TextEditingController();
  final TextEditingController remark = TextEditingController();

  /// 业务链溯源（从订单带明细时回填；保存随 salesOrderItemId 提交，
  /// 计划审核时按 1:1 link 回写 sales_order_items.planned_qty）。
  String? salesOrderItemId;
  String? clientName;

  /// 从已保存草稿读回的行 = 该计划明细 id，保存时随行回传，服务端据此认出「同一行」
  /// 沿用原比例来源(ADR-129 §2.10)；新增行为空，换货品后清空。
  String? sourceItemId;

  /// 该行所属来源订单的销售员（跟单员联动用；选/导入订单时回填）。
  String? sellerId;
  String? sellerName;
  double? unitRate; // 单位换算率（订单行带出；MRP 毛需求按基本单位折算依赖它）
  String? orderDate; // yyyy-MM-dd（订单日期）
  String? outboundDate; // yyyy-MM-dd（交货日）

  /// 颜色/单位（选货品后自动回填；颜色只读显示、单位作数量输入框后缀）。
  /// ValueNotifier 即时刷新。
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

  /// 深拷贝(明细复制/粘贴用)：拷产品编号/货品/颜色/单位/排产量/允许超产比例/备注，
  /// 以及读回行的 sourceItemId(复制的比例沿用原行的来源)。
  /// 不拷 salesOrderItemId（订单↔计划行 1:1 溯源，审核时回写 planned_qty——复制行
  /// 带旧 id 会双计）及订单带出的展示字段（订货量/订单号/客户/交期/跟单员/换算率）：
  /// 粘贴行等同手工自建行（与「添加行」后手选货品的字段空缺一致）。
  ProductionGridRow clone() {
    final c = ProductionGridRow()
      ..goods = goods
      ..colorId = colorId
      ..unitId = unitId
      ..sourceItemId = sourceItemId;
    c.productNo.text = productNo.text;
    c.qty.text = qty.text;
    c.overproductionPercent.text = overproductionPercent.text;
    c.remark.text = remark.text;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    qtyNotifier.dispose();
    productNo.dispose();
    qty.dispose();
    overproductionPercent.dispose();
    oqty.dispose();
    salesOrderNo.dispose();
    remark.dispose();
    super.dispose();
  }
}

/// 生产明细列：产品编号 / 货品（点选）/ 颜色（只读）/ 排产量 / 订货量 /
/// 关联销售订单号 / 备注。[onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）；
/// [colorEntries]/[unitEntries] 由编辑页从 masterNameServiceProvider 注入（颜色单元格
/// 显示名 + 排产量/订货量的单位后缀）。
List<EditableGridColumn<ProductionGridRow>> productionGridColumns({
  required Future<void> Function(ProductionGridRow row) onPickGoods,
  required Future<void> Function(ProductionGridRow row) onPickSalesOrder,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
}) {
  return [
    EditableGridColumn<ProductionGridRow>(
      key: 'productNo',
      label: '产品编号',
      width: 120,
      textOf: (r) => r.productNo.text,
      listenableOf: (r) => r.productNo,
      cellBuilder: (context, row) => TextField(
        controller: row.productNo,
        decoration: const InputDecoration(isDense: true, hintText: '留空由系统生成'),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      required: true,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**，
      // 不把编号拼进名称格。这里只放名称；编号见紧随其后的「编号」列，颜色也有
      // 独立列。注意「产品编号」列是计划行号（后端分配），
      // 不是货品编号，不能顶替。
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      // 格尾搜索/锁图标(16)计入自动加宽量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
          onTap: () => onPickGoods(row),
          child: InputDecorator(
            // 选择格统一内边距（2026-10-06 表格控件统一口径）。
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: UtenEditableGridCellSpec.pickerCellPadding,
            ),
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<GoodsOption?>(
                    valueListenable: row.goodsNotifier,
                    builder: (context, g, _) => g == null
                        ? Text(
                            '点击选择',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          )
                        : UtenGoodsIdentityCell(name: g.name),
                  ),
                ),
                const Icon(Icons.search_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      textOf: (r) => r.goods?.code ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => ValueListenableBuilder<GoodsOption?>(
        valueListenable: row.goodsNotifier,
        builder: (context, goods, _) => UtenGoodsAttributeCell(goods?.code),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      textOf: (r) => colorEntries[r.colorId ?? ''] ?? '',
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    // 2026-10-10 用户口径（全站表格数量口径）：独立「单位」列撤销，单位跟在
    // 排产量/订货量输入框后缀（suffixText）；换货品回填 unitId 时由
    // ValueListenableBuilder 即时换后缀。
    EditableGridColumn<ProductionGridRow>(
      key: 'qty',
      exactValueOf: (r) => r.qty.text,
      exactListenableOf: (r) => r.qty,
      label: '排产量',
      width: 130,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: _unitSuffixField(
          unitIdNotifier: row.unitIdNotifier,
          unitEntries: unitEntries,
          controller: row.qty,
        ),
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'allowedOverproductionRate',
      label: '允许超产比例',
      width: 152,
      numeric: true,
      textOf: (row) => '${row.overproductionPercent.text}%',
      listenableOf: (row) => row.overproductionPercent,
      cellBuilder: (context, row) => ProductionOverproductionRateField(
        key: ObjectKey(row),
        controller: row.overproductionPercent,
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'oqty',
      exactValueOf: (r) => r.oqty.text,
      exactListenableOf: (r) => r.oqty,
      label: '订货量',
      width: 130,
      numeric: true,
      cellBuilder: (context, row) => _unitSuffixField(
        unitIdNotifier: row.unitIdNotifier,
        unitEntries: unitEntries,
        controller: row.oqty,
      ),
    ),
    EditableGridColumn<ProductionGridRow>(
      key: 'salesOrderNo',
      label: '关联销售订单号',
      width: 150,
      textOf: (r) => r.salesOrderNo.text,
      listenableOf: (r) => r.salesOrderNo,
      // 格尾选择图标计入量宽。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => InkWell(
        onTap: () => onPickSalesOrder(row),
        child: InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: UtenEditableGridCellSpec.pickerCellPadding,
          ),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: row.salesOrderNo,
                  builder: (context, v, _) => Text(
                    v.text.isEmpty ? '点击选择' : v.text,
                    style: TextStyle(
                      color: v.text.isEmpty
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
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
      key: 'remark',
      label: '备注',
      width: 180,
      textOf: (r) => r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
  ];
}

/// 只读主档字段单元格（颜色自动回填后用）：显示 entries[id] 名，空显示「—」。
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
        style: TextStyle(
          color: hasName ? null : theme.colorScheme.onSurfaceVariant,
        ),
      );
    },
  );
}

/// 数量输入格 + 单位后缀（2026-10-10 数量内联口径）：单位名跟在输入框
/// suffixText，随 [unitIdNotifier] 换货品回填即时刷新；未选单位时无后缀。
Widget _unitSuffixField({
  required ValueNotifier<String?> unitIdNotifier,
  required Map<String, String> unitEntries,
  required TextEditingController controller,
}) {
  return ValueListenableBuilder<String?>(
    valueListenable: unitIdNotifier,
    builder: (context, unitId, _) {
      final unit = (unitId != null && unitId.isNotEmpty)
          ? unitEntries[unitId]
          : null;
      return TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          hintText: '0',
          suffixText: (unit == null || unit.isEmpty) ? null : unit,
        ),
      );
    },
  );
}
