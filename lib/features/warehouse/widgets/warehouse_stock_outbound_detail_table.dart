import 'package:flutter/material.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_doc.dart';

class WarehouseStockOutboundRow {
  const WarehouseStockOutboundRow(this.document, this.item);
  final StockDocDetail document;
  final StockDocItem item;
}

/// Single and batch outbound reviews use the same physical document facts.
class WarehouseStockOutboundDetailTable extends StatelessWidget {
  const WarehouseStockOutboundDetailTable({
    super.key,
    required this.documents,
    required this.names,
    this.primary = false,
    this.selectedIds = const {},
    this.onSelectedIdsChanged,
    this.canSelect,
    this.resultOf,
    this.batchActionsBuilder,
  });

  final List<StockDocDetail> documents;
  final MasterNameService names;
  final bool primary;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>>? onSelectedIdsChanged;
  final bool Function(StockDocDetail)? canSelect;
  final String Function(StockDocDetail)? resultOf;
  final List<Widget> Function(BuildContext, Set<String>)? batchActionsBuilder;

  @override
  Widget build(BuildContext context) {
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    return MasterDataTableView<WarehouseStockOutboundRow>(
      tableKey:
          'features.warehouse.widgets.warehouse_stock_outbound_detail_table.WarehouseStockOutboundDetailTable.build.1',
      key: const Key('warehouse-stock-outbound-detail-table'),
      primary: primary,
      showFullscreenToggle: false,
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      items: [
        for (final document in documents)
          for (final item in document.items)
            WarehouseStockOutboundRow(document, item),
      ],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      selectable: onSelectedIdsChanged != null,
      idOf: (row) =>
          canSelect?.call(row.document) == false ? null : row.document.id,
      rowKeyOf: (row) => '${row.document.id}:${row.item.id ?? row.item.lineNo}',
      selectedIds: selectedIds,
      onSelectedIdsChanged: onSelectedIdsChanged,
      batchActionsBuilder: batchActionsBuilder,
      emptyMessage: l10n.commonNoData,
      columns: [
        // 2026-10-08 用户口径「状态或进度列默认放最前」：处理结果列（已出库 /
        // 待出库 / 不可出库）是本批量出库表的行级结果列，推翻 2026-10-06 批次
        // 「无状态字样不动」的豁免，前置；仅在调用方给 resultOf 时出现。
        if (resultOf != null)
          MasterColumnDef(
            key: 'result',
            label: l10n.warehouseOutboundBatchResult,
            width: 250,
            value: (r) => resultOf!(r.document),
          ),
        MasterColumnDef(
          key: 'billNo',
          label: l10n.warehouseStockOutboundBillNo,
          info: l10n.warehouseStockOutboundHint,
          width: 170,
          value: (r) => r.document.billNo ?? '—',
        ),
        // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
        MasterColumnDef(
          key: 'goods',
          label: l10n.warehouseOutboundGoodsName,
          width: 220,
          value: (r) => names.goods(r.item.goodsId),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: l10n.warehouseOutboundGoodsCode,
          width: 125,
          value: (r) => names.goodsInfo(r.item.goodsId)?.code ?? '—',
        ),
        MasterColumnDef(
          key: 'color',
          label: l10n.warehouseOutboundColor,
          width: 90,
          value: (r) => names.color(r.item.colorId),
        ),
        MasterColumnDef(
          key: 'warehouse',
          label: l10n.warehouseSubcontractOutboundWarehouse,
          width: 165,
          value: (r) => names.warehouse(r.document.warehouseId),
        ),
        MasterColumnDef(
          key: 'series',
          label: l10n.warehouseStockOutboundSeries,
          width: 100,
          value: (r) => names.goodsInfo(r.item.goodsId)?.series ?? '—',
        ),
        MasterColumnDef(
          key: 'place',
          label: l10n.warehouseStockOutboundPlace,
          width: 110,
          value: (r) =>
              r.item.place?.trim().isNotEmpty == true ? r.item.place : '—',
        ),
        MasterColumnDef(
          key: 'suggestedPlace',
          label: l10n.warehouseOutboundPlaceHint,
          width: 135,
          value: (r) => names.goodsInfo(r.item.goodsId)?.stockPlace ?? '—',
        ),
        // 2026-10-10「数量 + 单位」内联口径：单位列删除，数量直接带单位。
        MasterColumnDef(
          key: 'qty',
          label: l10n.warehouseStockOutboundQuantity,
          width: 145,
          type: 'number',
          value: (r) => _quantityWithUnit(
            r.item.qty,
            names.unit(r.item.unitId),
          ),
        ),
        // 单据行重量 (千克) 按用户显示单位带单位显示; 没称「未称」, 不显示成 0。
        MasterColumnDef(
          key: 'weight',
          label: l10n.warehouseOutboundWeight,
          width: 110,
          type: 'number',
          value: (r) => formatWeightValue(r.item.weight),
          cellBuilder: (context, r) =>
              WeightText(kg: r.item.weight),
        ),
        MasterColumnDef(
          key: 'source',
          label: l10n.warehouseStockOutboundSource,
          width: 170,
          value: (r) => r.item.sourceDocNo ?? r.document.sourceDocNo ?? '—',
        ),
        MasterColumnDef(
          key: 'remark',
          label: l10n.warehouseSubcontractOutboundLineRemark,
          width: 200,
          value: (r) => r.item.remark ?? '—',
        ),
        MasterColumnDef(
          key: 'documentRemark',
          label: l10n.warehouseSubcontractOutboundDocumentRemark,
          width: 200,
          value: (r) => r.document.remark ?? '—',
        ),
      ],
    );
  }

  /// 数量 + 单位 (2026-10-10 内联口径)：单位列删除，单位直接跟数字；
  /// names.unit 未加载/未知返回「—」，拼装前滤掉，避免出现「5 —」；
  /// 数量保留 4 位小数、去尾零。
  static String _quantityWithUnit(double? value, String unitLabel) =>
      value == null
      ? '—'
      : formatQtyWithUnit(
          value,
          unitLabel == '—' ? null : unitLabel,
          maxDecimals: 4,
        );
}
