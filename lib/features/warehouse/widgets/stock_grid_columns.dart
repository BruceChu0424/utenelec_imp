// 仓库单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// StockGridRow：货品(选择) + 业务数量/实际总重量（非盘点）
// / 账面 + 实盘（盘点）→ 盘盈亏自动（AmountRowMixin）。
// 仓库单据无单价/金额概念；「金额」类比为盘点的"盘盈亏 = 实盘 - 账面"（仅 CHECK）。
// 非盘点类型 amountValue 恒 0（无金额列、无表尾合计）。
// stockGridColumns(onPickGoods, isCheck)：列 = 货品/数量（非盘点）
// 或 货品/账面/实盘/盘盈亏(自动)（盘点）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';

/// 仓库明细行。
/// - 非盘点（isCheck=false）：填 [qty]（带单位的数量）和可选 [weight]（本行实际总重量）。
/// - 盘点（isCheck=true）：填 [bookQty]（账面）+ [checkQty]（实盘）；
///   amountNotifier = 盘盈亏 = 实盘 - 账面（订阅两控制器自动重算）。
class StockGridRow extends EditableGridRow with AmountRowMixin {
  StockGridRow({this.isCheck = false, this.sourceLocked = false}) {
    // 仅盘点模式连线重算：非盘点无金额概念，amountNotifier 恒 0（不订阅省一次空更新）。
    if (isCheck) {
      bookQty.addListener(_recalc);
      checkQty.addListener(_recalc);
    }
  }

  final bool isCheck;
  final bool sourceLocked;
  String? upstreamItemId;
  String? executionSegmentId;
  String? executionSegmentSalesAllocationId;
  String? sourceDrawId;
  String? sourceDrawNo;
  String? colorId;
  String? unitId;
  double unitRate = 1;
  double? maxQty;

  // 只读主档展示（选品/载入时填充）：编号/系列/库位号/颜色名/单位名——仓库对位拣货用。
  String? goodsCode;
  String? goodsSeries;
  String? goodsStockPlace;
  String? colorName;
  String? unitName;

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  /// 非盘点模式的"数量"（对应后端 items.qty）。
  final TextEditingController qty = TextEditingController();

  /// 非盘点模式的本行实际总重量（对应后端 items.weight）；不得由单重静默估算。
  final TextEditingController weight = TextEditingController();

  /// 盘点模式的"账面数量"（对应后端 items.qty；后端按 surplusQty 联动库存）。
  final TextEditingController bookQty = TextEditingController();

  /// 盘点模式的"实盘数量"（对应后端 items.countQty）。
  final TextEditingController checkQty = TextEditingController();

  void _recalc() => recalcAmount(
    () =>
        (double.tryParse(checkQty.text) ?? 0) -
        (double.tryParse(bookQty.text) ?? 0),
  );

  /// 深拷贝（明细复制/粘贴用）：拷货品、录入量（非盘点=数量/重量；盘点=账面/实盘，
  /// 盘盈亏随控制器自动重算）与只读主档展示列。上游/执行段/退料来源引用与 maxQty
  /// 门控不拷——可编辑模式下本就为空，防御性排除。
  StockGridRow clone() {
    final c = StockGridRow(isCheck: isCheck)
      ..goods = goods
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..goodsCode = goodsCode
      ..goodsSeries = goodsSeries
      ..goodsStockPlace = goodsStockPlace
      ..colorName = colorName
      ..unitName = unitName;
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.bookQty.text = bookQty.text;
    c.checkQty.text = checkQty.text;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    weight.dispose();
    bookQty.dispose();
    checkQty.dispose();
    super.dispose();
  }
}

/// 仓库明细列。
/// - isCheck=false：货品 / 编码 / 系列 / 库位 / 颜色 / 单位 / 数量 / 实际重量。
/// - isCheck=true：货品 / 编码 / 系列 / 库位 / 颜色 / 单位 / 账面 / 实盘 / 盘盈亏(自动)。
///
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
List<EditableGridColumn<StockGridRow>> stockGridColumns(
  Future<void> Function(StockGridRow row) onPickGoods, {
  bool isCheck = false,
  bool isWdraw = false,
}) {
  return [
    EditableGridColumn<StockGridRow>(
      key: 'goods',
      label: '货品',
      width: 200,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
          onTap: row.sourceLocked ? null : () => onPickGoods(row),
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
                Icon(
                  row.sourceLocked ? Icons.lock_outline : Icons.search_rounded,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    // 编码/系列/库位/颜色/单位：行 model 普通字段（选货品后整行重建回填），
    // 无变更通知器可挂——只给 textOf（行集变化时整体量宽），不接实时加宽。
    EditableGridColumn<StockGridRow>(
      key: 'code',
      label: '物料编码',
      width: 110,
      textOf: (r) => r.goodsCode ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsCode ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'series',
      label: '系列',
      width: 80,
      textOf: (r) => r.goodsSeries ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsSeries ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'stockPlace',
      label: '库位号',
      width: 80,
      textOf: (r) => r.goodsStockPlace ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsStockPlace ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'color',
      label: '颜色',
      width: 80,
      textOf: (r) => r.colorName ?? '',
      cellBuilder: (context, row) => Text(
        row.colorName ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'unit',
      label: '单位',
      width: 64,
      textOf: (r) => r.unitName ?? '',
      cellBuilder: (context, row) => Text(
        row.unitName ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    if (isWdraw) ...[
      EditableGridColumn<StockGridRow>(
        key: 'source',
        label: '原领料单',
        width: 150,
        cellBuilder: (_, row) => Text(row.sourceDrawNo ?? '未选择来源'),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'maxReturn',
        label: '最多可退',
        width: 100,
        numeric: true,
        cellBuilder: (_, row) => Text(
          row.maxQty == null ? '—' : row.maxQty!.toStringAsFixed(4),
          textAlign: TextAlign.right,
        ),
      ),
    ],
    if (isCheck) ...[
      EditableGridColumn<StockGridRow>(
        key: 'bookQty',
        label: '账面',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          readOnly: true,
          controller: row.bookQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            isDense: true,
            filled: true,
            hintText: '选择货品后读取',
            suffixIcon: Icon(Icons.lock_outline, size: 16),
          ),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'checkQty',
        label: '实盘',
        width: 96,
        numeric: true,
        required: true,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.checkQty,
          isEmpty: () => row.checkQty.text.trim().isEmpty,
          child: TextField(
            controller: row.checkQty,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'surplus',
        label: '盘盈亏',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => ValueListenableBuilder<double>(
          valueListenable: row.amountNotifier,
          builder: (_, v, _) => Text(v.toStringAsFixed(2)),
        ),
      ),
    ] else ...[
      EditableGridColumn<StockGridRow>(
        key: 'qty',
        label: '数量',
        width: 96,
        numeric: true,
        required: true,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.qty,
          isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
          child: TextField(
            controller: row.qty,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'weight',
        label: '实际重量',
        width: 104,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.weight,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '可选'),
        ),
      ),
    ],
  ];
}
