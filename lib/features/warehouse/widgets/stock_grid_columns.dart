// 仓库单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// StockGridRow：货品(选择) + 数量（非盘点）/ 账面 + 实盘（盘点）→ 盘盈亏自动（AmountRowMixin）。
// 仓库单据无单价/金额概念；「金额」类比为盘点的"盘盈亏 = 实盘 - 账面"（仅 CHECK）。
// 非盘点类型 amountValue 恒 0（无金额列、无表尾合计）。
// stockGridColumns(onPickGoods, isCheck)：列 = 货品/数量（非盘点）
// 或 货品/账面/实盘/盘盈亏(自动)（盘点）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';

/// 仓库明细行。
/// - 非盘点（isCheck=false）：只填 [qty]（数量）。
/// - 盘点（isCheck=true）：填 [bookQty]（账面）+ [checkQty]（实盘）；
///   amountNotifier = 盘盈亏 = 实盘 - 账面（订阅两控制器自动重算）。
class StockGridRow extends EditableGridRow with AmountRowMixin {
  StockGridRow({this.isCheck = false}) {
    // 仅盘点模式连线重算：非盘点无金额概念，amountNotifier 恒 0（不订阅省一次空更新）。
    if (isCheck) {
      bookQty.addListener(_recalc);
      checkQty.addListener(_recalc);
    }
  }

  final bool isCheck;

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(null);
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  /// 非盘点模式的"数量"（对应后端 items.qty）。
  final TextEditingController qty = TextEditingController();

  /// 盘点模式的"账面数量"（对应后端 items.qty；后端按 surplusQty 联动库存）。
  final TextEditingController bookQty = TextEditingController();

  /// 盘点模式的"实盘数量"（对应后端 items.countQty）。
  final TextEditingController checkQty = TextEditingController();

  void _recalc() => recalcAmount(
      () => (double.tryParse(checkQty.text) ?? 0) - (double.tryParse(bookQty.text) ?? 0));

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    bookQty.dispose();
    checkQty.dispose();
    super.dispose();
  }
}

/// 仓库明细列。
/// - isCheck=false：货品 / 数量 两列（无金额、无表尾）。
/// - isCheck=true：货品 / 账面 / 实盘 / 盘盈亏(自动) 四列（表尾可合计盘盈亏）。
///
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
List<EditableGridColumn<StockGridRow>> stockGridColumns(
  Future<void> Function(StockGridRow row) onPickGoods, {
  bool isCheck = false,
}) {
  return [
    EditableGridColumn<StockGridRow>(
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
    if (isCheck) ...[
      EditableGridColumn<StockGridRow>(
        key: 'bookQty',
        label: '账面',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.bookQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'checkQty',
        label: '实盘',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.checkQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
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
    ] else
      EditableGridColumn<StockGridRow>(
        key: 'qty',
        label: '数量',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
  ];
}
