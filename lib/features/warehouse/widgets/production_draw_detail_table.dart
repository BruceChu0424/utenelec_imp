import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/outbound_weight_entry.dart';
import '../models/stock_doc.dart';
import '../models/production_draw_discovery_row.dart';
import 'outbound_weight_columns.dart';

/// 单张领料和批量出库共用的逐物料明细，来源始终随所属单据展示。
class ProductionDrawDetailRow {
  const ProductionDrawDetailRow(this.document, this.item) : discovery = null;
  const ProductionDrawDetailRow.discovery(this.discovery)
    : document = null,
      item = null;

  final StockDocDetail? document;
  final StockDocItem? item;
  final ProductionDrawDiscoveryRow? discovery;
}

/// 一行待出库行的校验结果（页面提交前逐行核对）。
String? drawIssueQtyError(ProductionDrawDetailRow row, String input) {
  final value = double.tryParse(input.trim());
  if (value == null || !value.isFinite) return '请输入有效数量';
  if (value < 0) return '数量不能为负';
  if (value == 0) return '出库数量需大于 0';
  if (row.item != null && value > row.item!.remainingQty + 1e-9) {
    return '不能超过待出库 ${row.item!.remainingQty}';
  }
  return null;
}

/// 领料明细一行的本次重量录入 (ADR-135 §3.6): 数量 = 本次出库 (可改, 空着时按称重推算),
/// 按行单位换算率换成基本单位核对偏差。
OutboundWeightEntry drawIssueWeightEntry(
  StockDocItem item,
  UtenAutofillTextController qty, {
  WeightUnit unit = WeightUnit.kg,
}) => OutboundWeightEntry(
  goodsId: item.goodsId,
  qtyOf: () => double.tryParse(qty.text.trim()),
  qtyController: qty,
  unitRate: item.unitRate ?? 1,
  unit: unit,
);

/// 批量整单出库 (本次 = 待出库) 的一行本次重量录入。
OutboundWeightEntry drawRemainingWeightEntry(
  StockDocItem item, {
  WeightUnit unit = WeightUnit.kg,
}) => OutboundWeightEntry(
  goodsId: item.goodsId,
  qtyOf: () => item.remainingQty,
  unitRate: item.unitRate ?? 1,
  unit: unit,
);

class ProductionDrawDetailTable extends StatelessWidget {
  const ProductionDrawDetailTable({
    super.key,
    required this.documents,
    required this.names,
    required this.permissions,
    this.superAdmin = false,
    this.primary = false,
    this.issueQtyControllers,
    this.lineRemarkControllers,
    this.issueWeights,
    this.weightParams,
    this.weightEntryUnit = WeightUnit.kg,
    this.issueSaving = false,
    this.discoveryRows = const [],
    this.onPickDiscoveryWarehouse,
    this.showDiscoveryValidation = false,
    this.onSplitDiscoveryRow,
    this.onRemoveDiscoveryRow,
    this.canRemoveDiscoveryRow,
  });

  final List<StockDocDetail> documents;
  final MasterNameService names;
  final Set<String> permissions;
  final bool superAdmin;
  final bool primary;

  /// 2026-09-12 用户口径「数量在表格里改，出库只弹总结」：单张详情页传入
  /// 逐行「本次出库」数量与「行备注」控制器（键=item.id，页面持有随路由销毁）；
  /// null = 只读（批量出库视图等）。控制器由页面在 _load 后重建。
  final Map<String, UtenAutofillTextController>? issueQtyControllers;
  final Map<String, TextEditingController>? lineRemarkControllers;

  /// 本次重量 (ADR-135 §3.6, 键=item.id): 单张详情页紧跟「本次出库」, 批量页紧跟
  /// 「待出库」(整单按剩余量出库); 材料申请行的重量在 [ProductionDrawDiscoveryRow.weight]。
  /// null 且没有材料申请行 = 不采集重量。
  final Map<String, OutboundWeightEntry>? issueWeights;

  /// 页内单重参数缓存 (占位「应称」与偏差核对); null = 只记重量不核对。
  final WeightParamsCache? weightParams;

  /// 录入单位 (用户偏好 warehouse.weightUnits.entry)。
  final WeightUnit weightEntryUnit;

  /// 出库提交中：输入格禁用（只读防抖动）。
  final bool issueSaving;
  final List<ProductionDrawDiscoveryRow> discoveryRows;
  final ValueChanged<ProductionDrawDiscoveryRow>? onPickDiscoveryWarehouse;
  final bool showDiscoveryValidation;
  final ValueChanged<ProductionDrawDiscoveryRow>? onSplitDiscoveryRow;
  final ValueChanged<ProductionDrawDiscoveryRow>? onRemoveDiscoveryRow;
  final bool Function(ProductionDrawDiscoveryRow)? canRemoveDiscoveryRow;

  bool get _capturesWeight => issueWeights != null || discoveryRows.isNotEmpty;

  OutboundWeightEntry? _weightOf(ProductionDrawDetailRow row) =>
      row.discovery?.weight ?? issueWeights?[row.item?.id];

  /// 物料的基本单位名 (件数说明用)。
  String? _baseUnitName(String? goodsId) {
    final unitId = names.goodsInfo(goodsId)?.unitId;
    return unitId == null ? null : names.unit(unitId);
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final document in documents)
        for (final item in document.items)
          ProductionDrawDetailRow(document, item),
      for (final row in discoveryRows) ProductionDrawDetailRow.discovery(row),
    ];
    // 称重计数弹窗标题要货品名/编号/颜色: 按录入行找回所在明细行。
    final rowOfEntry = <OutboundWeightEntry, ProductionDrawDetailRow>{
      for (final row in rows) ?_weightOf(row): row,
    };
    final entries = rowOfEntry.keys.toList(growable: false);
    final weightColumns = _capturesWeight
        ? [
            outboundWeightColumn<ProductionDrawDetailRow>(
              key: 'issueWeight',
              label: '本次重量',
              entryOf: _weightOf,
              entryUnit: weightEntryUnit,
              params: weightParams,
              enabledOf: (row) =>
                  !issueSaving &&
                  (row.discovery != null || (row.item?.remainingQty ?? 0) > 0),
              baseUnitNameOf: (entry) => _baseUnitName(entry.goodsId),
              onWeighCount: (context, entry) {
                final row = rowOfEntry[entry];
                return weighOutboundEntry(
                  context,
                  entry: entry,
                  goodsTitle: row == null ? '' : _goodsTitle(row),
                  cache: weightParams,
                  baseUnitName: _baseUnitName(entry.goodsId),
                  lineUnitName: row == null ? null : _unitName(row),
                  warehouseId:
                      row?.document?.warehouseId ??
                      row?.discovery?.values['warehouseId'] as String?,
                  sampleRemark: row?.document?.billNo,
                );
              },
            ),
            outboundWeightCheckColumn<ProductionDrawDetailRow>(
              entryOf: _weightOf,
              params: weightParams,
              unitNameOf: (entry) => _baseUnitName(entry.goodsId),
            ),
          ]
        : const <MasterColumnDef<ProductionDrawDetailRow>>[];
    final documentWeightShown = documents.any(
      (document) =>
          !document.productionLinked &&
          document.items.any((item) => item.weight != null),
    );
    return MasterDataTableView<ProductionDrawDetailRow>(
      key: const Key('production-draw-detail-table'),
      primary: primary,
      enableTextSelection: !_capturesWeight && issueQtyControllers == null,
      rowKeyOf: (row) =>
          row.discovery?.id ?? '${row.document!.id}:${row.item!.id}',
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      toolbarActions: _capturesWeight ? const [WeightEntryUnitButton()] : null,
      summaryBar: _capturesWeight && entries.isNotEmpty
          ? OutboundWeightSummaryBar(entries: entries, params: weightParams)
          : null,
      columns: [
        MasterColumnDef(
          // 2026-09-25 单号列统一：明细就地排序+按值筛选。
          key: 'billNo',
          sortable: true,
          filterFromRows: true,
          label: '领料单号',
          width: 160,
          value: (row) => _numberLabel(row.document?.billNo),
        ),
        MasterColumnDef(
          key: 'materialRequestNo',
          label: '领料申请号',
          width: 170,
          sortable: true,
          filterFromRows: true,
          value: (row) => _numberLabel(
            row.discovery?.request.requestNo ?? row.document?.materialRequestNo,
          ),
        ),
        // 2026-09-14 全站列序统一(ADR-081 §4.1)：名称 → 编号 → 颜色。
        MasterColumnDef(
          key: 'goods',
          label: '货品名称',
          width: 200,
          value: (row) =>
              row.discovery?.label('goodsName') ??
              names.goods(row.item!.goodsId),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 120,
          value: (row) =>
              row.discovery?.label('goodsCode') ??
              names.goodsInfo(row.item!.goodsId)?.code ??
              '—',
        ),
        // 颜色列原来排在库位号之后(第 8 列)，仓库拣货要横滚才看得到：同名不同色
        // 在本系统很常见，编号/名称/颜色必须在前几列同屏可见，故上移紧跟货品名称。
        // 已有独立颜色列，货品列就不再重复带颜色。
        MasterColumnDef(
          key: 'color',
          label: '颜色',
          width: 90,
          value: (row) =>
              row.discovery?.label('colorName') ??
              names.color(row.item!.colorId),
        ),
        MasterColumnDef(
          key: 'warehouse',
          label: discoveryRows.isEmpty ? '仓库' : '仓库 *',
          width: discoveryRows.isEmpty ? 160 : 200,
          value: (row) =>
              row.discovery?.label('warehouseName') ??
              names.warehouse(row.document!.warehouseId),
          cellBuilder: (context, row) => row.discovery == null
              ? Text(names.warehouse(row.document!.warehouseId))
              : _discoveryWarehouseCell(context, row.discovery!),
        ),
        MasterColumnDef(
          key: 'department',
          label: '领料车间',
          width: 150,
          value: (row) =>
              row.discovery?.request.workshopName ??
              names.department(row.document!.departmentId),
        ),
        // 姓名由详情接口随单返回(workerName): 单张详情/批量出库页都不再预加载员工档案,
        // 仓库/车间账号没有 employee:view 也能看到是谁来领料。
        MasterColumnDef(
          key: 'worker',
          label: '领料负责人',
          width: 140,
          value: (row) => row.discovery == null
              ? names.employeeOr(
                  row.document!.workerName,
                  row.document!.workerId,
                )
              : '—',
        ),
        MasterColumnDef(
          key: 'place',
          label: '库位号',
          width: 100,
          value: (row) =>
              row.discovery?.label('stockPlace') ??
              (row.item!.place?.trim().isNotEmpty == true
                  ? row.item!.place!
                  : names.goodsInfo(row.item!.goodsId)?.stockPlace ?? '—'),
        ),
        MasterColumnDef(key: 'unit', label: '单位', width: 70, value: _unitName),
        MasterColumnDef(
          key: 'qty',
          label: discoveryRows.isEmpty ? '应领数量' : '应领数量 *',
          width: discoveryRows.isEmpty ? 105 : 180,
          type: 'number',
          value: (row) =>
              row.discovery?.quantity.text ?? _quantity(row.item!.qty ?? 0),
          cellBuilder: (context, row) => row.discovery == null
              ? Text(_quantity(row.item!.qty ?? 0))
              : _discoveryQuantityCell(context, row.discovery!),
        ),
        MasterColumnDef(
          key: 'requestedQty',
          label: '已申请领料',
          width: 105,
          type: 'number',
          value: (row) => row.discovery == null
              ? _quantity(row.item!.requestedQty ?? row.item!.qty ?? 0)
              : '待确认',
        ),
        MasterColumnDef(
          key: 'issuedQty',
          label: '已出库',
          width: 105,
          type: 'number',
          value: (row) =>
              row.discovery == null ? _quantity(row.item!.issuedQty ?? 0) : '0',
        ),
        // 已出库重量 = 本行各轮出库流水重量合计 (服务端按流水算, 估算带「≈」)。
        MasterColumnDef(
          key: 'issuedWeight',
          label: '已出库重量',
          width: 120,
          type: 'number',
          info: '各轮出库实称/分摊的重量合计(已扣取消出库); 「≈」为按库存均重或单重估算。',
          value: (row) => _issuedWeightText(row.item),
          cellBuilder: (context, row) {
            final item = row.item;
            if (item == null || (item.issuedQty ?? 0) <= 0) {
              return const Text('—');
            }
            return WeightText(
              kg: item.issuedWeightKg,
              estimated: item.issuedWeightEstimated,
              textAlign: TextAlign.right,
            );
          },
        ),
        MasterColumnDef(
          key: 'remainingQty',
          label: '待出库',
          width: 105,
          type: 'number',
          value: (row) =>
              row.discovery == null ? _quantity(row.item!.remainingQty) : '待确认',
        ),
        // 批量整单出库没有「本次出库」列: 本次重量紧跟「待出库」(本次 = 待出库)。
        if (issueQtyControllers == null) ...weightColumns,
        // 2026-09-12：本次出库数量与行备注在表格内编辑(默认=待出库)，
        // 出库按钮只弹总结确认——弹窗里不再改数字、不再传附件。
        if (issueQtyControllers != null) ...[
          MasterColumnDef(
            key: 'issueQty',
            label: '本次出库',
            width: 120,
            value: (row) => issueQtyControllers![row.item?.id]?.text ?? '',
            cellBuilder: (context, row) {
              final controller = issueQtyControllers![row.item?.id];
              if (controller == null) return const Text('—');
              return Semantics(
                textField: true,
                label: '${names.goods(row.item?.goodsId)} 本次出库数量',
                child: _autofillQuantityField(
                  context,
                  key: ValueKey('draw-issue-qty-${row.item?.id}'),
                  controller: controller,
                  weight: _weightOf(row),
                  enabled: !issueSaving && (row.item?.remainingQty ?? 0) > 0,
                ),
              );
            },
          ),
          ...weightColumns,
        ],
        if (lineRemarkControllers != null)
          MasterColumnDef(
            key: 'lineRemark',
            label: '行备注',
            width: 160,
            value: (row) => lineRemarkControllers![row.item?.id]?.text ?? '',
            cellBuilder: (context, row) {
              final controller = lineRemarkControllers![row.item?.id];
              if (controller == null) return const Text('—');
              return Semantics(
                textField: true,
                label: '${names.goods(row.item?.goodsId)} 行备注',
                child: TextField(
                  key: ValueKey('draw-issue-remark-${row.item?.id}'),
                  controller: controller,
                  enabled: !issueSaving && (row.item?.remainingQty ?? 0) > 0,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '选填',
                    counterText: '',
                  ),
                ),
              );
            },
          ),
        MasterColumnDef(
          key: 'issueStatus',
          label: '出库进度',
          width: 120,
          value: (row) => row.discovery == null
              ? drawIssueStatusLabel(row.document!.issueStatus)
              : '待确认出库',
        ),
        MasterColumnDef(
          key: 'planNo',
          label: '生产计划',
          width: 170,
          value: (row) =>
              row.discovery?.request.planNo ?? row.document?.planNo ?? '—',
          cellBuilder: (context, row) => _sourceLink(
            context,
            row.discovery?.request.planNo ?? row.document?.planNo,
            row.document?.sourcePlanId == null
                ? null
                : RoutePath.productionPlanDetail(row.document!.sourcePlanId!),
          ),
        ),
        MasterColumnDef(
          key: 'sourceDocNo',
          label: '来源',
          width: 170,
          value: (row) =>
              row.discovery?.request.segmentCode ??
              row.item?.sourceDocNo ??
              row.document?.sourceDocNo ??
              '—',
          cellBuilder: (context, row) => _sourceLink(
            context,
            row.discovery?.request.segmentCode ??
                row.item?.sourceDocNo ??
                row.document?.sourceDocNo,
            row.document?.sourceDailyReportId == null
                ? null
                : '/production/daily-reports/${row.document!.sourceDailyReportId}',
          ),
        ),
        MasterColumnDef(
          key: 'series',
          label: '系列',
          width: 90,
          value: (row) =>
              row.discovery?.label('series') ??
              names.goodsInfo(row.item?.goodsId)?.series ??
              '—',
        ),
        // 手工领料单编辑时录的单据重量 (生产链领料单没有, 出库重量看「已出库重量」)。
        if (documentWeightShown)
          MasterColumnDef(
            key: 'documentWeight',
            label: '单据重量',
            width: 110,
            type: 'number',
            value: (row) => row.item?.weight == null
                ? '—'
                : formatWeightValue(row.item!.weight),
            cellBuilder: (context, row) => row.item?.weight == null
                ? const Text('—')
                : WeightText(kg: row.item!.weight, textAlign: TextAlign.right),
          ),
        MasterColumnDef(
          key: 'remark',
          label: '备注',
          width: 200,
          value: (row) => row.item?.remark ?? row.document?.remark ?? '—',
        ),
        if (discoveryRows.isNotEmpty) ...[
          MasterColumnDef(
            key: 'spec',
            label: '规格',
            width: 140,
            value: (row) => row.discovery?.label('spec') ?? '—',
          ),
          MasterColumnDef(
            key: 'usedFor',
            label: '用于生产',
            width: 280,
            value: (row) =>
                row.discovery?.productionDescription ??
                row.document?.planNo ??
                '—',
          ),
          MasterColumnDef(
            key: 'discoveryActions',
            label: '分仓发料',
            width: 136,
            value: (_) => '',
            cellBuilderHandlesSemantics: true,
            cellBuilder: (_, row) {
              final discovery = row.discovery;
              if (discovery == null) return const Text('—');
              return Wrap(
                children: [
                  IconButton(
                    key: ValueKey('draw-discovery-split-${discovery.id}'),
                    tooltip: '拆分到其他发料仓',
                    onPressed: issueSaving || onSplitDiscoveryRow == null
                        ? null
                        : () => onSplitDiscoveryRow!(discovery),
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    key: ValueKey('draw-discovery-remove-${discovery.id}'),
                    tooltip: '删除分仓行(每种材料至少保留一行)',
                    onPressed:
                        issueSaving ||
                            onRemoveDiscoveryRow == null ||
                            canRemoveDiscoveryRow?.call(discovery) != true
                        ? null
                        : () => onRemoveDiscoveryRow!(discovery),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              );
            },
          ),
        ],
      ],
      items: rows,
      emptyMessage: '暂无领料明细',
    );
  }

  String _unitName(ProductionDrawDetailRow row) =>
      row.discovery?.label('unitName') ?? names.unit(row.item!.unitId);

  /// 称重计数弹窗标题「货品名 编号 颜色」。
  String _goodsTitle(ProductionDrawDetailRow row) {
    final discovery = row.discovery;
    final parts = discovery != null
        ? [
            discovery.label('goodsName'),
            discovery.label('goodsCode'),
            discovery.label('colorName'),
          ]
        : [
            names.goods(row.item!.goodsId),
            names.goodsInfo(row.item!.goodsId)?.code ?? '',
            row.item!.colorId == null ? '' : names.color(row.item!.colorId),
          ];
    return parts.where((p) => p.trim().isNotEmpty && p != '—').join(' ');
  }

  static String _issuedWeightText(StockDocItem? item) {
    if (item == null || (item.issuedQty ?? 0) <= 0) return '—';
    return formatWeightValue(
      item.issuedWeightKg,
      estimated: item.issuedWeightEstimated,
    );
  }

  /// 可按称重推算的数量格: 推算值黄框预填, ⓘ 说明推算区间。
  Widget _autofillQuantityField(
    BuildContext context, {
    required Key key,
    required UtenAutofillTextController controller,
    required OutboundWeightEntry? weight,
    required bool enabled,
    bool readOnly = false,
    String? hintText,
    Widget? error,
    bool requiredEmpty = false,
  }) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: controller,
    builder: (context, _, _) {
      final theme = Theme.of(context);
      final autofilled = controller.autofilled;
      return TextField(
        key: key,
        controller: controller,
        enabled: enabled,
        readOnly: readOnly,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: applyAutofillHint(
          applyRequiredEmpty(
            UtenInputDecoration(
              InputDecoration(isDense: true, hintText: hintText, error: error),
              info: autofilled
                  ? (weight?.weight.qtyEstimateNote ?? '按称重推算')
                  : null,
            ),
            theme,
            requiredEmpty: requiredEmpty,
          ),
          theme,
          autofilled: autofilled,
        ),
      );
    },
  );

  Widget _discoveryQuantityCell(
    BuildContext context,
    ProductionDrawDiscoveryRow row,
  ) => _autofillQuantityField(
    context,
    key: ValueKey('draw-discovery-qty-${row.id}'),
    controller: row.quantity,
    weight: row.weight,
    enabled: true,
    readOnly: issueSaving,
    hintText: '需要填写',
    error: showDiscoveryValidation && row.quantityError != null
        ? UtenFieldMessage.error(row.quantityError!)
        : null,
    requiredEmpty: row.quantity.text.trim().isEmpty,
  );

  Widget _discoveryWarehouseCell(
    BuildContext context,
    ProductionDrawDiscoveryRow row,
  ) => TextButton(
    key: ValueKey('draw-discovery-warehouse-${row.id}'),
    onPressed: issueSaving || onPickDiscoveryWarehouse == null
        ? null
        : () => onPickDiscoveryWarehouse!(row),
    child: InputDecorator(
      decoration: applyRequiredEmpty(
        UtenInputDecoration(
          InputDecoration(
            isDense: true,
            error: showDiscoveryValidation && row.warehouseError != null
                ? UtenFieldMessage.error(row.warehouseError!)
                : null,
          ),
        ),
        Theme.of(context),
        requiredEmpty: row.warehouseError != null,
      ),
      child: Text(
        row.warehouseError == null ? row.label('warehouseName') : '需要选择实际仓',
      ),
    ),
  );

  Widget _sourceLink(BuildContext context, String? number, String? path) {
    final label = number?.isNotEmpty == true ? number! : '—';
    if (path == null ||
        number?.isNotEmpty != true ||
        !locationAllowedFor(permissions, superAdmin, path)) {
      return Text(label);
    }
    return TextButton(
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.zero,
      ),
      onPressed: () => context.push(path),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');

  static String _numberLabel(String? number) =>
      number?.trim().isNotEmpty == true ? number!.trim() : '—';
}
