// 即时库存与仓库资料共用同一列定义；库存投影已包含主档信息，避免额外申请 goods:view。
// 数量/重量显示与只读列范围只有一份，成本仍由独立授权的服务端导出裁列。
import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../formatters/quantity_display.dart';
import '../formatters/money_display.dart';
import '../measurement/weight_unit.dart';
import '../measurement/widgets/weight_text.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import 'instant_inventory_row.dart';

List<MasterColumnDef<InstantInventoryRow>> instantInventoryColumns(
  BuildContext context, {
  required WeightDisplay weightDisplay,
  bool? columnSearchEnabled,
  bool canViewCost = false,
  bool periodSelected = false,
  bool periodLoading = false,
  bool periodError = false,
}) {
  String periodValue(
    InstantInventoryRow row,
    double? value, {
    bool money = false,
    bool price = false,
  }) {
    if (!periodSelected) return '请选择时间范围';
    if (periodLoading) return '计算中';
    if (periodError) return '统计加载失败，请重试';
    if (!row.periodSelected) return '期间统计不可用，请刷新';
    if (money && row.costMasked) return '已隐藏';
    if (value == null) return '—';
    if (price) return '${formatQty(value)} 元';
    if (money) return financeLocalMoneyWithUnitSuffix(value.toString());
    return formatQtyWithUnit(
      value,
      row.measurementPending ? null : row.unitName,
    );
  }

  return <MasterColumnDef<InstantInventoryRow>>[
    // 先辨认货品和颜色，再看现存数量/重量及待处理量；
    // 库位和主档属性放在库存事实后面，备注收尾。
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'name',
      label: '货品名称',
      width: 220,
      sortable: true,
      value: (r) => r.name ?? '',
      cellBuilder: (context, r) => Row(
        children: [
          Expanded(
            child: Text(
              r.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (r.isRelatedSearchMatch) ...[
            const SizedBox(width: UtenSpacing.s8),
            Text('相关', style: Theme.of(context).textTheme.labelSmall),
          ],
        ],
      ),
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (r) => r.goodsCode ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'color',
      label: '颜色',
      width: 90,
      value: (r) => r.colorName ?? '',
    ),
    // 2026-10-10「数量+单位」全站口径：单位内联在数字后（12 PCS），独立
    // 「单位」列退役；实盘数量输入格的后缀在共享输入格（stock_count_inline_editor）。
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'qty',
      label: '库存数量',
      width: 185,
      type: 'number',
      sortable: true,
      value: (r) => r.measurementPending
          ? '${formatQty(r.qty)}（${r.measurementNotice}）'
          : formatQtyWithUnit(r.qty, r.unitName),
      // ADR-146: 打开「含不良品仓」时, 数量里在不良品仓的部分另标出来。
      cellBuilder: (context, r) {
        if (r.measurementPending) {
          return Tooltip(
            message: '${r.measurementNotice}。主档补单位不代表原账计量已经核验。',
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatQty(r.qty),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  r.measurementNotice,
                  style: Theme.of(context).textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        }
        final qty = formatQtyWithUnit(r.qty, r.unitName);
        final defective = r.defectiveQty ?? 0;
        if (defective <= 0) return Text(qty);
        return Text(
          '$qty (${AppLocalizations.of(context).instantInventoryDefectivePart(formatQty(defective))})',
          key: ValueKey(
            'instant-inventory-defective-${r.goodsId}-${r.colorId}',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    ),
    if (canViewCost) ...[
      MasterColumnDef(
        key: 'costPrice',
        label: '成本价',
        width: 165,
        type: 'money',
        sortable: periodSelected,
        columnSearchEnabled: false,
        info: '截止日的库存台账金额 ÷ 结存数量；结存为零时不计算单价。单位：本币元/基本单位。',
        value: (r) => periodValue(r, r.costPrice, money: true, price: true),
      ),
      MasterColumnDef(
        key: 'periodCostAmount',
        label: '成本金额',
        width: 170,
        type: 'money',
        sortable: periodSelected,
        columnSearchEnabled: false,
        info: '所选截止日的库存台账本币金额，与上方仓库范围一致。',
        value: (r) => periodValue(r, r.periodCostAmount, money: true),
      ),
    ],
    MasterColumnDef(
      key: 'periodInQty',
      label: '进仓数量',
      width: 170,
      type: 'number',
      sortable: periodSelected,
      columnSearchEnabled: false,
      info: '所选期间入库净量，含退货与红冲；所选仓库范围内调拨不重复计入。',
      value: (r) => periodValue(r, r.periodInQty),
    ),
    MasterColumnDef(
      key: 'periodOutQty',
      label: '发货数量',
      width: 170,
      type: 'number',
      sortable: periodSelected,
      columnSearchEnabled: false,
      info: '所选期间出仓净量，含销售发货、领料等出库及其红冲；范围内调拨不重复计入。',
      value: (r) => periodValue(r, r.periodOutQty),
    ),
    MasterColumnDef(
      key: 'closingQty',
      label: '结存数量',
      width: 170,
      type: 'number',
      sortable: periodSelected,
      columnSearchEnabled: false,
      info: '所选截止日结束时的结存；库存数量列仍显示当前实时库存。',
      value: (r) => periodValue(r, r.closingQty),
    ),
    // 库存重量：千克按用户显示单位换算，估算「≈」、没称「未称」。
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'weight',
      label: '库存重量',
      width: 120,
      type: 'weight',
      sortable: true,
      value: (r) => formatWeightValue(
        r.weight,
        display: weightDisplay,
        estimated: r.weightEstimated,
        unknownText: r.weightUnknown || (r.qty ?? 0) != 0
            ? weightUnknownText
            : '—',
      ),
      cellBuilder: (_, r) => WeightText(
        kg: r.weight,
        estimated: r.weightEstimated,
        display: weightDisplay,
        unknownText: r.weightUnknown || (r.qty ?? 0) != 0
            ? weightUnknownText
            : '—',
      ),
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'pendingQty',
      label: '待检量',
      width: 135,
      type: 'number',
      sortable: true,
      // 待检量>0 = 采购/委外已收货但 IQC 未放行（货在待检隔离区，不在库存内）。
      value: (r) => formatQtyWithUnit(
        r.pendingQty,
        r.measurementPending ? null : r.unitName,
      ),
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'pendingStockInQty',
      label: '合格待入库',
      width: 150,
      type: 'number',
      sortable: true,
      // 品质 PASS 只形成仓库任务；仓库确认前不进入库存数量。
      value: (r) => formatQtyWithUnit(
        r.pendingStockInQty,
        r.measurementPending ? null : r.unitName,
      ),
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'stockPlace',
      label: '库位号',
      width: 90,
      value: (r) => r.stockPlace ?? '',
    ),
    // 所属仓库 (V587)：货品平时归哪个仓管的主档归属，只读。
    // 列 key 是 owningWarehouse，不能叫 warehouse —— 本页顶部的仓库筛选是
    // 另一回事 (那是本次看盘的范围仓)，两者绝不是同一个概念。
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'owningWarehouse',
      label: '主档归属仓库',
      width: 120,
      info: '货品平时归哪个仓管的主档归属，不是这行库存所在的仓，也不是上面的仓库筛选值。',
      value: (r) => r.owningWarehouseName?.trim() ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'category',
      label: '所属类型',
      width: 120,
      value: (r) => r.categoryName ?? '—',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'model',
      label: '型号',
      width: 110,
      value: (r) => r.model ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'spec',
      label: '规格',
      width: 120,
      value: (r) => r.spec ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'cNumber',
      label: '客户型号',
      width: 120,
      value: (r) => r.cNumber ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'series',
      label: '物料系列',
      width: 90,
      value: (r) => r.series ?? '',
    ),
    MasterColumnDef(
      columnSearchEnabled: columnSearchEnabled,
      key: 'remark',
      label: '备注',
      width: 90,
      value: (r) => r.remark ?? '',
    ),
  ];
}
