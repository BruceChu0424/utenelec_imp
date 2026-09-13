import 'package:flutter/material.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
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
        MasterColumnDef(
          key: 'billNo',
          label: l10n.warehouseStockOutboundBillNo,
          info: l10n.warehouseStockOutboundHint,
          width: 170,
          value: (r) => r.document.billNo ?? '—',
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: l10n.warehouseOutboundGoodsCode,
          width: 125,
          value: (r) => names.goodsInfo(r.item.goodsId)?.code ?? '—',
        ),
        MasterColumnDef(
          key: 'goods',
          label: l10n.warehouseOutboundGoodsName,
          width: 220,
          value: (r) => names.goods(r.item.goodsId),
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
        MasterColumnDef(
          key: 'color',
          label: l10n.warehouseOutboundColor,
          width: 90,
          value: (r) => names.color(r.item.colorId),
        ),
        MasterColumnDef(
          key: 'unit',
          label: l10n.warehouseOutboundUnit,
          width: 75,
          value: (r) => names.unit(r.item.unitId),
        ),
        MasterColumnDef(
          key: 'qty',
          label: l10n.warehouseStockOutboundQuantity,
          width: 110,
          type: 'number',
          value: (r) => _quantity(r.item.qty),
        ),
        MasterColumnDef(
          key: 'weight',
          label: l10n.warehouseOutboundWeight,
          width: 100,
          type: 'number',
          value: (r) => _quantity(r.item.weight),
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
        if (resultOf != null)
          MasterColumnDef(
            key: 'result',
            label: l10n.warehouseOutboundBatchResult,
            width: 250,
            value: (r) => resultOf!(r.document),
          ),
      ],
    );
  }

  static String _quantity(double? value) => value == null
      ? '—'
      : value
            .toStringAsFixed(4)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
}
