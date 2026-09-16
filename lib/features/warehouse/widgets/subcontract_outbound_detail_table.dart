import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../models/subcontract_outbound.dart';

String subcontractOutboundQuantity(double value) =>
    value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();

/// One plan UUID remains attached to each editable quantity, including when
/// several orders contain the same goods and colour.
class SubcontractOutboundLineDraft {
  SubcontractOutboundLineDraft(
    this.line,
    this.draftItemId,
    String initialQty,
    String initialWeight, {
    String? remark,
    this.unitRate,
  }) : qty = TextEditingController(text: initialQty),
       weight = TextEditingController(text: initialWeight),
       remarkController = TextEditingController(text: remark ?? ''),
       ownDraftQty = draftItemId == null ? 0 : double.tryParse(initialQty) ?? 0;

  final OutboundPlanLine line;
  final String? draftItemId;
  final TextEditingController qty;
  final TextEditingController weight;
  final double ownDraftQty;
  final TextEditingController remarkController;
  String? get remark => remarkController.text.trim().isEmpty
      ? null
      : remarkController.text.trim();
  final double? unitRate;
  bool selected = true;

  // A plan can have drafts in several real warehouses. Reuse this draft's
  // quantity only; other drafts' reservations belong to their own EC documents.
  double get maxEditableQty => line.maxEditableQty == 0
      ? 0
      : draftItemId == null
      ? line.readyOutboundQty
      : ownDraftQty;

  String? validate(AppLocalizations l10n) {
    if (!selected) return null;
    final quantity = double.tryParse(qty.text.trim());
    if (quantity == null ||
        !quantity.isFinite ||
        quantity <= 0 ||
        quantity - maxEditableQty > 0.0000001) {
      return l10n.warehouseSubcontractOutboundQuantityInvalid;
    }
    final weightText = weight.text.trim();
    final actualWeight = double.tryParse(weightText);
    if (weightText.isNotEmpty &&
        (actualWeight == null || !actualWeight.isFinite || actualWeight <= 0)) {
      return l10n.warehouseSubcontractOutboundWeightInvalid;
    }
    return null;
  }

  Map<String, dynamic> toPayload() => {
    ...line.toMaterialIssueItemPayload(
      qty: double.parse(qty.text.trim()),
      weight: double.tryParse(weight.text.trim()),
    ),
    'remark': remark,
    if (unitRate != null) 'unitRate': unitRate,
  };

  void dispose() {
    qty.dispose();
    weight.dispose();
    remarkController.dispose();
  }
}

class SubcontractOutboundTableRow extends EditableGridRow {
  SubcontractOutboundTableRow({
    required this.draft,
    required this.warehouse,
    this.orderBillNo,
    this.supplierName,
    this.editable = true,
    this.documentNo,
    this.documentRemark,
    this.warehouseId,
    this.warehouses = const [],
    this.onWarehouseChanged,
    this.status,
  });

  final SubcontractOutboundLineDraft draft;
  final String warehouse;
  final String? orderBillNo;
  final String? supplierName;
  final bool editable;
  final String? documentNo;
  final String? status;
  final TextEditingController? documentRemark;
  final String? warehouseId;
  final List<WarehouseDictEntry> warehouses;
  final ValueChanged<String?>? onWarehouseChanged;
}

/// Shared by single-plan picking and batch picking. It uses the same compact,
/// horizontally scrollable table as the inbound confirmation pages.
class SubcontractOutboundDetailTable extends StatefulWidget {
  const SubcontractOutboundDetailTable({
    super.key,
    required this.rows,
    required this.editable,
    required this.onChanged,
    this.showOrder = false,
    this.selectable = false,
    this.onRowSelected,
  });
  final List<SubcontractOutboundTableRow> rows;
  final bool editable;
  final bool showOrder;
  final bool selectable;
  final void Function(SubcontractOutboundTableRow row, bool selected)?
  onRowSelected;
  final VoidCallback onChanged;

  @override
  State<SubcontractOutboundDetailTable> createState() =>
      _SubcontractOutboundDetailTableState();
}

class _SubcontractOutboundDetailTableState
    extends State<SubcontractOutboundDetailTable> {
  final _grid = UtenEditableGridController<SubcontractOutboundTableRow>();

  @override
  void initState() {
    super.initState();
    _grid.replaceAll(widget.rows);
  }

  @override
  void didUpdateWidget(covariant SubcontractOutboundDetailTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    _grid.replaceAll(widget.rows);
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    EditableGridColumn<SubcontractOutboundTableRow> textColumn(
      String key,
      String label,
      double width,
      String Function(SubcontractOutboundTableRow) value, {
      bool numeric = false,
      String? info,
    }) => EditableGridColumn(
      key: key,
      label: label,
      width: width,
      numeric: numeric,
      headerInfo: info,
      textOf: value,
      cellBuilder: (_, row) =>
          Text(value(row), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    EditableGridColumn<SubcontractOutboundTableRow> quantityColumn(
      String key,
      String label,
      double Function(SubcontractOutboundTableRow) value,
    ) => textColumn(
      key,
      label,
      115,
      (row) => subcontractOutboundQuantity(value(row)),
      numeric: true,
    );
    return UtenEditableGrid<SubcontractOutboundTableRow>(
      key: const Key('subcontract-outbound-detail-table'),
      controller: _grid,
      showAddRow: false,
      showRowDelete: false,
      showColumnSettings: true,
      showSelectAllToggle: false,
      showRemoveRowsAction: false,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
      // 不再「编号 名称」拼一格；历史父件同样拆名称 + 编号。
      // 委外发料最容易错的就是同名不同色（自制白色 / 委外香槟金）——
      // 名称/编号/颜色在前几列同屏可见。
      initialColumnOrder: const [
        'document',
        'goodsName',
        'goodsCode',
        'color',
        'warehouse',
        'quantity',
        'unit',
        'maximum',
        'weight',
        'place',
        'lineRemark',
        'documentRemark',
        'planned',
        'prepared',
        'issued',
        'order',
        'supplier',
        'status',
        'legacyParentName',
        'legacyParentCode',
      ],
      selectable: widget.editable && widget.selectable,
      selectionEnabled: widget.editable,
      canSelectRow: (row) => row.editable,
      selectedOf: (row) => row.draft.selected,
      onRowSelect: (row, next) {
        widget.onRowSelected?.call(row, next);
        widget.onChanged();
      },
      emptyMessage: l10n.warehouseSubcontractOutboundNoLines,
      columns: [
        if (widget.showOrder)
          textColumn(
            'document',
            l10n.warehouseStockOutboundBillNo,
            180,
            (row) => row.documentNo ?? '—',
            info:
                '${l10n.warehouseSubcontractOutboundReviewHint}\n${l10n.warehouseSubcontractOutboundBatchHint}',
          ),
        if (widget.showOrder)
          textColumn(
            'order',
            l10n.warehouseSubcontractOutboundOrder,
            180,
            (row) => row.orderBillNo ?? '—',
          ),
        if (widget.showOrder)
          textColumn(
            'supplier',
            l10n.warehouseSubcontractOutboundSupplier,
            150,
            (row) => row.supplierName ?? '—',
          ),
        textColumn(
          'goodsName',
          l10n.warehouseSubcontractOutboundGoodsName,
          200,
          (row) => row.draft.line.goodsName ?? '—',
        ),
        textColumn(
          'goodsCode',
          l10n.warehouseSubcontractOutboundGoodsCode,
          130,
          (row) => row.draft.line.goodsCode ?? '—',
        ),
        if (widget.rows.any(
          (row) =>
              row.draft.line.flowMode ==
              SubcontractOutboundFlowMode.legacyBomComponent,
        )) ...[
          textColumn(
            'legacyParentName',
            l10n.warehouseSubcontractOutboundLegacyParentName,
            200,
            (row) =>
                row.draft.line.flowMode ==
                    SubcontractOutboundFlowMode.legacyBomComponent
                ? row.draft.line.parentGoodsName ?? '—'
                : '—',
          ),
          textColumn(
            'legacyParentCode',
            l10n.warehouseSubcontractOutboundLegacyParentCode,
            130,
            (row) =>
                row.draft.line.flowMode ==
                    SubcontractOutboundFlowMode.legacyBomComponent
                ? row.draft.line.parentGoodsCode ?? '—'
                : '—',
          ),
        ],
        textColumn(
          'color',
          l10n.warehouseSubcontractOutboundColor,
          100,
          (row) => row.draft.line.colorName ?? '—',
        ),
        textColumn(
          'unit',
          l10n.warehouseSubcontractOutboundUnit,
          80,
          (row) => row.draft.line.unitName ?? '—',
        ),
        quantityColumn(
          'planned',
          l10n.warehouseSubcontractOutboundPlanned,
          (row) => row.draft.line.plannedQty,
        ),
        quantityColumn(
          'prepared',
          l10n.warehouseSubcontractOutboundPrepared,
          (row) => row.draft.line.preparedQty,
        ),
        quantityColumn(
          'issued',
          l10n.warehouseSubcontractOutboundIssued,
          (row) => row.draft.line.issuedQty,
        ),
        quantityColumn(
          'maximum',
          l10n.warehouseSubcontractOutboundAvailable,
          (row) => row.draft.maxEditableQty,
        ),
        EditableGridColumn(
          key: 'quantity',
          label: l10n.warehouseSubcontractOutboundQuantity,
          width: 150,
          required: true,
          numeric: true,
          textOf: (row) => row.draft.qty.text,
          listenableOf: (row) => row.draft.qty,
          cellBuilder: (context, row) => RequiredCellFrame(
            listenable: row.draft.qty,
            isEmpty: () {
              final value = double.tryParse(row.draft.qty.text.trim());
              return row.draft.selected &&
                  (value == null ||
                      !value.isFinite ||
                      value <= 0 ||
                      value - row.draft.maxEditableQty > 0.0000001);
            },
            child: _field(
              row,
              row.draft.qty,
              l10n.warehouseSubcontractOutboundQuantity,
              'quantity',
            ),
          ),
        ),
        EditableGridColumn(
          key: 'weight',
          label: l10n.warehouseSubcontractOutboundWeight,
          width: 150,
          numeric: true,
          textOf: (row) => row.draft.weight.text,
          listenableOf: (row) => row.draft.weight,
          cellBuilder: (context, row) => _field(
            row,
            row.draft.weight,
            l10n.warehouseSubcontractOutboundWeight,
            'weight',
          ),
        ),
        EditableGridColumn(
          key: 'warehouse',
          label: l10n.warehouseSubcontractOutboundWarehouse,
          width: 230,
          required: true,
          headerInfo: l10n.warehouseSubcontractOutboundWarehouseSyncHint,
          textOf: (row) => row.warehouse,
          cellBuilder: (_, row) => row.onWarehouseChanged == null
              ? Text(row.warehouse)
              : WarehouseHierarchyDropdown(
                  key: ValueKey(
                    'subcontract-outbound-${row.draft.draftItemId ?? row.draft.line.planItemId}-warehouse',
                  ),
                  entries: row.warehouses,
                  value: row.warehouseId,
                  enabled:
                      widget.editable && row.editable && row.draft.selected,
                  labelText: l10n.warehouseSubcontractOutboundWarehouse,
                  onChanged: row.onWarehouseChanged!,
                ),
        ),
        textColumn(
          'place',
          l10n.warehouseSubcontractOutboundPlace,
          120,
          (row) => row.draft.line.goodsStockPlace ?? '—',
        ),
        EditableGridColumn(
          key: 'lineRemark',
          label: l10n.warehouseSubcontractOutboundLineRemark,
          width: 240,
          textOf: (row) => row.draft.remarkController.text,
          listenableOf: (row) => row.draft.remarkController,
          cellBuilder: (_, row) => _remarkField(
            row,
            row.draft.remarkController,
            l10n.warehouseSubcontractOutboundLineRemark,
            'remark',
          ),
        ),
        if (widget.rows.any((row) => row.documentRemark != null))
          EditableGridColumn(
            key: 'documentRemark',
            label: l10n.warehouseSubcontractOutboundDocumentRemark,
            width: 240,
            headerInfo: l10n.warehouseSubcontractOutboundDocumentRemarkHint,
            textOf: (row) => row.documentRemark?.text ?? '',
            listenableOf: (row) => row.documentRemark,
            cellBuilder: (_, row) => row.documentRemark == null
                ? const Text('—')
                : _remarkField(
                    row,
                    row.documentRemark!,
                    l10n.warehouseSubcontractOutboundDocumentRemark,
                    'document-remark',
                  ),
          ),
        if (widget.rows.any((row) => row.status != null))
          textColumn(
            'status',
            l10n.warehouseSubcontractOutboundStatus,
            150,
            (row) => row.status ?? '—',
          ),
      ],
    );
  }

  Widget _remarkField(
    SubcontractOutboundTableRow row,
    TextEditingController controller,
    String label,
    String suffix,
  ) => TextField(
    key: ValueKey(
      'subcontract-outbound-${row.draft.draftItemId ?? row.draft.line.planItemId}-$suffix',
    ),
    controller: controller,
    enabled: widget.editable && row.editable && row.draft.selected,
    maxLength: 200,
    decoration: UtenInputDecoration(
      InputDecoration(labelText: label, isDense: true, counterText: ''),
    ),
  );

  Widget _field(
    SubcontractOutboundTableRow row,
    TextEditingController controller,
    String label,
    String suffix,
  ) => Semantics(
    textField: true,
    label: label,
    child: TextField(
      key: ValueKey(
        'subcontract-outbound-${row.draft.draftItemId ?? row.draft.line.planItemId}-$suffix',
      ),
      controller: controller,
      enabled: widget.editable && row.editable && row.draft.selected,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}$')),
      ],
      decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
    ),
  );
}
