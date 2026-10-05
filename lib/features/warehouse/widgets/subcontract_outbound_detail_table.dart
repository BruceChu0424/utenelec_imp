import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../subcontract/models/subcontract_doc.dart';
import '../models/outbound_weight_entry.dart';
import '../models/subcontract_outbound.dart';
import 'outbound_weight_columns.dart';

String subcontractOutboundQuantity(double value) =>
    value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();

/// 本次出库数量不合法(空 / 非数字 / 负数 / 超过委外提交的领料数量)。0 = 本次不发。
const String subcontractOutboundQuantityInvalid =
    '本次出库数量要在 0 到委外提交的领料数量之间(填 0 表示这条物料本次不发)';

/// 一张领料单每行都填了 0：整单不发不能靠删光明细，要退回委外。
const String subcontractOutboundNothingToIssue = '整单不发请点「退回委外(不发)」或联系委外人员撤回领料';

/// 「本次出库数量」列头说明(单张拣货页与批量出库页同一口径)。
const String subcontractOutboundQuantityHint =
    '只能改少，不能超过领料数量。某条物料这次不发就填 0：保存后这一行从领料单删掉，'
    '占用的库存退回，委外下次领料时可以再领。';

/// 实称重量格里有看不懂的输入。
const String subcontractOutboundWeightInvalid = '实称重量看不懂，请改成如 12.5 或 850g';

/// 审核出仓确认弹窗里说明的效果(单张拣货页与批量出库页同一口径)。
const String subcontractOutboundApproveEffects =
    '审核后将：\n'
    '① 所列直属物料从所选仓库实际出库，交委外商加工；\n'
    '② 改少或填 0 不发的物料不会丢：委外下次领料时系统自动补齐；\n'
    '③ 委外商加工完交回的是委外件，回厂后仍需登记和品质检查，合格后才正式入仓。';

/// 领料单的一条可拣货明细：[line] 是服务端拣货视图(领料数量 / 库位 / 回厂委外件)，
/// [item] 是同一行在出仓单草稿里的原样明细(货品、颜色、单位、来源链 UUID)。
/// 仓库只能把数量改少(0 ≤ 数量 ≤ [OutboundPickLine.requestedQty])，不能改多、不能加行；
/// 填 0 = 本次不发这条物料，保存时不回传这一行，服务端删行并退回它占用的库存。
class SubcontractOutboundLineDraft {
  SubcontractOutboundLineDraft(
    this.line,
    this.item, {
    WeightUnit weightUnit = WeightUnit.kg,
  }) : qty = UtenAutofillTextController(
         text: subcontractOutboundQuantity(item.qty ?? line.qty),
         autofilled: false,
       ),
       remarkController = TextEditingController(text: item.remark ?? '') {
    weight = OutboundWeightEntry(
      goodsId: item.goodsId ?? line.goodsId,
      colorId: item.colorId,
      qtyOf: () => double.tryParse(qty.text.trim()),
      qtyController: qty,
      unitRate: item.unitRate ?? 1,
      kg: item.weight,
      qtyFromWeight: item.qtyFromWeight,
      unit: weightUnit,
    );
    // 已保存草稿里「数量按称重推算」的行：数量保留黄框并说明来源(与仓库单据编辑页同口径)。
    if (weight.qtyFromWeight && weight.kg != null && qty.text.isNotEmpty) {
      final initial = qty.text;
      qty.setAutomaticText(initial);
      weight.weight.markQtyDerived(initial, note: '保存时按称重折算的数量');
    }
  }

  final OutboundPickLine line;
  final SubcontractDocItem item;

  /// 本次出库数量 (空着时可按称重推算, 黄框预填)。
  final UtenAutofillTextController qty;

  /// 仓库实称重量 (ADR-135 §3.8): 随草稿保存, 审核出仓时落委外出仓流水。
  late final OutboundWeightEntry weight;
  final TextEditingController remarkController;
  String? get remark => remarkController.text.trim().isEmpty
      ? null
      : remarkController.text.trim();
  bool selected = true;

  /// 出仓单草稿明细 id(保存时原样回传, 服务端据此只改数量不换行)。
  String get draftItemId => item.id ?? line.issueItemId;

  /// 本次最多 = 委外提交的领料数量; 只能改少不能改多。
  double get maxEditableQty => line.requestedQty;

  /// 填了 0 = 本次不发这条物料(保存时不回传这一行)。
  bool get skipped => double.tryParse(qty.text.trim()) == 0;

  String? validate() {
    if (!selected) return null;
    final quantity = double.tryParse(qty.text.trim());
    if (quantity == null ||
        !quantity.isFinite ||
        quantity < 0 ||
        quantity - maxEditableQty > 0.0000001) {
      return subcontractOutboundQuantityInvalid;
    }
    if (quantity == 0) return null;
    if (weight.weight.hasError) return subcontractOutboundWeightInvalid;
    return null;
  }

  /// 按出仓单草稿原行回传: 货品/颜色/单位/来源链 UUID 不由客户端重选, 只改数量、
  /// 实称重量和行备注。
  Map<String, dynamic> toPayload() => {
    'id': draftItemId,
    if (item.lineNo != null) 'lineNo': item.lineNo,
    'goodsId': item.goodsId ?? line.goodsId,
    'colorId': item.colorId,
    'unitId': item.unitId,
    'unitRate': item.unitRate ?? 1,
    'qty': double.parse(qty.text.trim()),
    'weight': ?weight.kg,
    'qtyFromWeight': weight.qtyFromWeight,
    'orderItemId': item.orderItemId,
    'planItemId': line.planItemId,
    if (item.parentGoodsId != null) 'parentGoodsId': item.parentGoodsId,
    if (item.parentColorId != null) 'parentColorId': item.parentColorId,
    'remark': remark,
  };

  void dispose() {
    weight.dispose();
    qty.dispose();
    remarkController.dispose();
  }
}

/// 保存回传的明细：只回传本次要发的行(数量 > 0)；填 0 的行不回传，服务端删行退库存。
/// 一行都不发时返回空列表，调用方提示 [subcontractOutboundNothingToIssue]，不调服务端。
List<Map<String, dynamic>> subcontractOutboundPayloadItems(
  Iterable<SubcontractOutboundLineDraft> lines,
) => [
  for (final line in lines)
    if (!line.skipped) line.toPayload(),
];

/// 把领料单拣货视图 [task] 与它自己的出仓单草稿 [document] 按草稿明细 id 一一对上。
///
/// 对不上(行数不同 / 有拣货行在草稿里找不到)返回 null: 说明单据在两次读取之间被
/// 撤回或改过, 调用方按「单据已变」处理, 绝不按货品去猜行。
List<SubcontractOutboundLineDraft>? subcontractOutboundLinesOf(
  OutboundTaskDetail task,
  SubcontractDocDetail document, {
  WeightUnit weightUnit = WeightUnit.kg,
}) {
  final byId = <String, SubcontractDocItem>{
    for (final item in document.items)
      if (item.id != null) item.id!: item,
  };
  if (task.lines.isEmpty ||
      task.lines.length != document.items.length ||
      byId.length != document.items.length ||
      task.lines.map((line) => line.issueItemId).toSet().length !=
          task.lines.length ||
      task.lines.any(
        (line) => byId[line.issueItemId]?.planItemId != line.planItemId,
      )) {
    return null;
  }
  return [
    for (final line in task.lines)
      SubcontractOutboundLineDraft(
        line,
        byId[line.issueItemId]!,
        weightUnit: weightUnit,
      ),
  ];
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

/// Shared by single-document picking and batch picking. It uses the same
/// compact, horizontally scrollable table as the inbound confirmation pages.
///
/// 实称重量 (ADR-135 §3.8) 紧跟「单位」: 选填, 占位「应称 X」, 偏差框只提醒;
/// 本次出库数量空着时填重量按称重推算数量 (黄框, 行打上 qtyFromWeight)。
/// 单重参数由表格自己按行批量取 (页内缓存, 离开页面释放)。
class SubcontractOutboundDetailTable extends ConsumerStatefulWidget {
  const SubcontractOutboundDetailTable({
    super.key,
    required this.rows,
    required this.editable,
    required this.onChanged,
    this.showOrder = false,
    this.selectable = false,
    this.onRowSelected,
    this.stickyHeaderPinned,
    this.primary = false,
    this.bottomContentPadding = 0,
  });
  final List<SubcontractOutboundTableRow> rows;
  final bool editable;
  final bool showOrder;
  final bool selectable;

  /// 表头吸顶信号（全站表格滚动口径 2026-09-22）；null = 表头随页滚动。
  final ValueNotifier<bool>? stickyHeaderPinned;

  /// 联动折叠模式(与 MasterDataTableView 同名口径): true 时表格自带一个拾取祖先
  /// UtenCollapsingHeaderScrollView 注入的 PrimaryScrollController 的竖向滚动件,
  /// 放在 body 的 Expanded 里即可内滚; false 时随页面自己的 ListView 滚。
  final bool primary;

  /// 表格内容末尾的可滚留白(与 MasterDataTableView 同名), 悬浮动作组盖不住末行。
  /// 仅 [primary] 模式生效。
  final double bottomContentPadding;
  final void Function(SubcontractOutboundTableRow row, bool selected)?
  onRowSelected;
  final VoidCallback onChanged;

  @override
  ConsumerState<SubcontractOutboundDetailTable> createState() =>
      _SubcontractOutboundDetailTableState();
}

class _SubcontractOutboundDetailTableState
    extends ConsumerState<SubcontractOutboundDetailTable> {
  final _grid = UtenEditableGridController<SubcontractOutboundTableRow>();

  /// 本次 build 盯住的页内单重参数缓存 (有明细行时才建)。
  WeightParamsCache? _weightCache;

  @override
  void initState() {
    super.initState();
    _grid.replaceAll(widget.rows);
    _ensureWeightParams();
  }

  @override
  void didUpdateWidget(covariant SubcontractOutboundDetailTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    _grid.replaceAll(widget.rows);
    _ensureWeightParams();
  }

  /// 下一帧 (缓存已在 build 里盯住) 补齐缺的单重参数; 已有/在途的不重复取。
  void _ensureWeightParams() {
    for (final row in widget.rows) {
      row.draft.weight.warehouseId = row.warehouseId;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ensureOutboundWeightParams(_weightCache, [
        for (final row in widget.rows) row.draft.weight,
      ]);
    });
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
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    _weightCache = widget.rows.isEmpty
        ? null
        : ref.watch(weightParamsCacheProvider);
    final weightCache = _weightCache;
    bool rowEditable(SubcontractOutboundTableRow row) =>
        widget.editable && row.editable && row.draft.selected;
    EditableGridColumn<SubcontractOutboundTableRow> textColumn(
      String key,
      String label,
      double width,
      String Function(SubcontractOutboundTableRow) value, {
      bool numeric = false,
      String? info,
      String? Function(SubcontractOutboundTableRow)? exactValue,
    }) => EditableGridColumn(
      key: key,
      label: label,
      width: width,
      numeric: numeric,
      headerInfo: info,
      textOf: value,
      exactValueOf: exactValue,
      cellBuilder: (_, row) =>
          Text(value(row), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    EditableGridColumn<SubcontractOutboundTableRow> quantityColumn(
      String key,
      String label,
      double? Function(SubcontractOutboundTableRow) value, {
      String? info,
    }) => textColumn(
      key,
      label,
      115,
      (row) {
        final quantity = value(row);
        return quantity == null ? '—' : subcontractOutboundQuantity(quantity);
      },
      numeric: true,
      info: info,
      exactValue: (row) => value(row)?.toString(),
    );
    final grid = UtenEditableGrid<SubcontractOutboundTableRow>(
      tableKey:
          'features.warehouse.widgets.subcontract_outbound_detail_table.SubcontractOutboundDetailTableState.build.1',
      key: const Key('subcontract-outbound-detail-table'),
      controller: _grid,
      stickyHeaderPinned: widget.stickyHeaderPinned,
      showAddRow: false,
      showRowDelete: false,
      showSelectAllToggle: false,
      showRemoveRowsAction: false,
      toolbarActions: const [WeightEntryUnitButton()],
      footer: widget.rows.isEmpty
          ? null
          : OutboundWeightSummaryBar(
              entries: [for (final row in widget.rows) row.draft.weight],
              params: weightCache,
            ),
      // 2026-09-14 用户口径(全站表格统一)：名称 / 编号 / 颜色各占一列。
      // 委外发料最容易错的就是同名不同色——名称/编号/颜色在前几列同屏可见;
      // 「领料数量」紧跟数量组, 仓库一眼看出只能改少到多少。
      initialColumnOrder: const [
        'document',
        'goodsName',
        'goodsCode',
        'color',
        'warehouse',
        'quantity',
        'unit',
        // 实称重量紧跟数量组 (数量 + 单位) 之后 (ADR-135 §3.8)。
        'weight',
        'requested',
        'stockAvailable',
        'place',
        // 每条明细都是某个委外件的直属物料: 这两列是回厂交回的委外件。
        'parentGoodsName',
        'parentGoodsCode',
        'lineRemark',
        'documentRemark',
        'order',
        'supplier',
        'status',
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
        textColumn(
          'parentGoodsName',
          l10n.warehouseSubcontractOutboundParentName,
          200,
          (row) => row.draft.line.parentGoodsName ?? '—',
          info: '上面几列是发给委外商的物料; 这一列是委外商加工后交回的委外件, 回厂时按它登记。',
        ),
        textColumn(
          'parentGoodsCode',
          l10n.warehouseSubcontractOutboundParentCode,
          130,
          (row) => row.draft.line.parentGoodsCode ?? '—',
        ),
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
        weightGridColumn<SubcontractOutboundTableRow>(
          controllerOf: (row) => row.draft.weight.weight,
          entryUnit: weightUnits.entry,
          mode: WeightCaptureMode.outbound,
          paramsOf: weightCache == null
              ? null
              : (row) => row.draft.weight.paramsIn(weightCache),
          paramsListenable: weightCache,
          qtyBaseOf: (row) => row.draft.weight.qtyBase,
          qtyListenableOf: (row) => row.draft.qty,
          enabledOf: rowEditable,
          qtyAutofill: WeightQtyAutofill<SubcontractOutboundTableRow>(
            qtyControllerOf: (row) => row.draft.qty,
            unitRateOf: (row) => row.draft.item.unitRate ?? 1,
            enabledOf: rowEditable,
          ),
          onWeighCount: (context, row) => weighOutboundEntry(
            context,
            entry: row.draft.weight,
            goodsTitle: [
              row.draft.line.goodsName,
              row.draft.line.goodsCode,
              row.draft.line.colorName,
            ].whereType<String>().join(' '),
            cache: weightCache,
            lineUnitName: row.draft.line.unitName,
            warehouseId: row.warehouseId,
            sampleRemark: row.documentNo,
          ),
        ),
        quantityColumn(
          'requested',
          '领料数量',
          (row) => row.draft.line.requestedQty,
          info:
              '委外人员提交的领料数量。本次出库只能小于或等于它, 填 0 表示这次不发; '
              '少发、不发的部分, 委外下次领料时系统会自动补齐。',
        ),
        quantityColumn(
          'stockAvailable',
          l10n.warehouseSubcontractOutboundStockAvailable,
          (row) => row.draft.line.stockAvailableQty,
          info: '领料单所在仓里这条物料当前可动用的合格数量, 用于核对实物。',
        ),
        EditableGridColumn(
          key: 'quantity',
          exactValueOf: (row) => row.draft.qty.text,
          exactListenableOf: (row) => row.draft.qty,
          label: l10n.warehouseSubcontractOutboundQuantity,
          width: 150,
          required: true,
          numeric: true,
          headerInfo: subcontractOutboundQuantityHint,
          textOf: (row) => row.draft.qty.text,
          listenableOf: (row) => row.draft.qty,
          cellBuilder: (context, row) => RequiredCellFrame(
            listenable: row.draft.qty,
            isEmpty: () {
              final value = double.tryParse(row.draft.qty.text.trim());
              return row.draft.selected &&
                  (value == null ||
                      !value.isFinite ||
                      value < 0 ||
                      value - row.draft.maxEditableQty > 0.0000001);
            },
            child: _quantityField(
              row,
              l10n.warehouseSubcontractOutboundQuantity,
            ),
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
                    'subcontract-outbound-${row.draft.draftItemId}-warehouse',
                  ),
                  entries: row.warehouses,
                  value: row.warehouseId,
                  enabled:
                      widget.editable && row.editable && row.draft.selected,
                  // 格内浮动标签与列头「发出仓」重复，已删（2026-09-27 表格小字清理）。
                  labelText: null,
                  onChanged: row.onWarehouseChanged!,
                ),
        ),
        textColumn(
          'place',
          l10n.warehouseSubcontractOutboundPlace,
          120,
          (row) => row.draft.line.locationHint ?? '—',
        ),
        EditableGridColumn(
          key: 'lineRemark',
          label: l10n.warehouseSubcontractOutboundLineRemark,
          width: 240,
          textOf: (row) => row.draft.remarkController.text,
          listenableOf: (row) => row.draft.remarkController,
          cellBuilder: (_, row) =>
              _remarkField(row, row.draft.remarkController, 'remark'),
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
                : _remarkField(row, row.documentRemark!, 'document-remark'),
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
    if (!widget.primary) return grid;
    // 网格本身是 content-tall 的 sticky 表头网格, 自己不滚; primary 模式下包一层
    // 拾取 PrimaryScrollController 的 ListView, 表头吸顶量位就以它为祖先视口。
    return ListView(
      primary: true,
      padding: EdgeInsets.only(bottom: widget.bottomContentPadding),
      children: [grid],
    );
  }

  Widget _remarkField(
    SubcontractOutboundTableRow row,
    TextEditingController controller,
    String suffix,
  ) => TextField(
    key: ValueKey('subcontract-outbound-${row.draft.draftItemId}-$suffix'),
    controller: controller,
    enabled: widget.editable && row.editable && row.draft.selected,
    maxLength: 200,
    // 格内浮动标签与列头（行备注/单据备注）重复，已删（2026-09-27 表格小字清理）。
    decoration: const UtenInputDecoration(
      InputDecoration(isDense: true, counterText: ''),
    ),
  );

  /// 本次出库数量格: 按称重推算的数量黄框预填, ⓘ 说明推算区间; 填 0 时 ⓘ 说明本次不发。
  Widget _quantityField(SubcontractOutboundTableRow row, String label) =>
      Semantics(
        textField: true,
        label: label,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: row.draft.qty,
          builder: (context, _, _) {
            final autofilled = row.draft.qty.autofilled;
            return TextField(
              key: ValueKey(
                'subcontract-outbound-${row.draft.draftItemId}-quantity',
              ),
              controller: row.draft.qty,
              enabled: widget.editable && row.editable && row.draft.selected,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}$')),
              ],
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  const InputDecoration(isDense: true),
                  info: autofilled
                      ? (row.draft.weight.weight.qtyEstimateNote ?? '按称重推算')
                      : row.draft.skipped
                      ? '本次不发：保存后这一行从领料单删掉，占用的库存退回'
                      : null,
                ),
                Theme.of(context),
                autofilled: autofilled,
              ),
            );
          },
        ),
      );
}
