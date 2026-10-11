import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/outbound_weight_entry.dart';
import '../models/stock_doc.dart';
import '../models/production_draw_discovery_row.dart';
import 'outbound_weight_columns.dart';

/// 单张领料和批量出库共用的逐物料明细，来源始终随所属单据展示。
class ProductionDrawDetailRow {
  const ProductionDrawDetailRow(this.document, this.item)
    : discovery = null,
      group = null;
  const ProductionDrawDetailRow.discovery(this.discovery)
    : document = null,
      item = null,
      group = null;

  /// 同批次同货品的合并组（2026-09-27 用户口径「批量出库里只合并相同批次的
  /// 相同货品」）：组员按 document/item 逐行出库，本行只是显示聚合。
  const ProductionDrawDetailRow.merged(this.group)
    : document = null,
      item = null,
      discovery = null;

  final StockDocDetail? document;
  final StockDocItem? item;
  final ProductionDrawDiscoveryRow? discovery;
  final List<ProductionDrawDetailRow>? group;

  bool get isMergedGroup => group != null;

  /// 行稳定键（MasterDataTableView 行 key 与双击判定共用）：合并行 document/item
  /// 均为 null，组身份就是「批次|货品|颜色」，必须给键而不能走 null 断言——
  /// 否则合并行 build 直接抛空检查异常，整行渲染成错误占位盒。
  String get stableRowKey {
    final discovery = this.discovery;
    if (discovery != null) return discovery.id;
    if (isMergedGroup) {
      final first = group!.first;
      return 'merged:${first.document!.drawBatchNo}|${first.item!.goodsId}|${first.item!.colorId}';
    }
    return '${document!.id}:${item!.id}';
  }
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
  String? warehouseId,
}) => OutboundWeightEntry(
  goodsId: item.goodsId,
  colorId: item.colorId,
  warehouseId: warehouseId,
  qtyOf: () => double.tryParse(qty.text.trim()),
  qtyController: qty,
  unitRate: item.unitRate ?? 1,
  unit: unit,
);

/// 批量整单出库 (本次 = 待出库) 的一行本次重量录入。
OutboundWeightEntry drawRemainingWeightEntry(
  StockDocItem item, {
  WeightUnit unit = WeightUnit.kg,
  String? warehouseId,
}) => OutboundWeightEntry(
  goodsId: item.goodsId,
  colorId: item.colorId,
  warehouseId: warehouseId,
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
    this.mergeBatchGoods = false,
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

  /// 批量出库页启用：同批次（drawBatchNo）同货品的明细行合并成一行显示数量
  /// 合计；出库仍按底层单据逐张全量提交（页面不填行级数量）。
  final bool mergeBatchGoods;

  /// 明细视图行：mergeBatchGoods 时把同批次（drawBatchNo 非空）同货品同颜色的
  /// 多行合并成一行（数量合计、单号显示张数）；discovery 行与无批次行不合并。
  List<ProductionDrawDetailRow> get viewRows {
    final base = <ProductionDrawDetailRow>[
      for (final document in documents)
        for (final item in document.items)
          ProductionDrawDetailRow(document, item),
      for (final row in discoveryRows) ProductionDrawDetailRow.discovery(row),
    ];
    if (!mergeBatchGoods) return base;
    final byKey = <String, List<ProductionDrawDetailRow>>{};
    for (final row in base) {
      final doc = row.document;
      final item = row.item;
      final batch = doc?.drawBatchNo ?? '';
      if (batch.isEmpty || item == null) continue;
      byKey
          .putIfAbsent('$batch|${item.goodsId}|${item.colorId}', () => [])
          .add(row);
    }
    final result = <ProductionDrawDetailRow>[];
    final seen = <String>{};
    for (final row in base) {
      final doc = row.document;
      final item = row.item;
      final batch = doc?.drawBatchNo ?? '';
      final key = batch.isEmpty || item == null
          ? ''
          : '$batch|${item.goodsId}|${item.colorId}';
      if (key.isEmpty) {
        result.add(row);
        continue;
      }
      if (!seen.add(key)) continue;
      final group = byKey[key]!;
      result.add(
        group.length == 1
            ? group.single
            : ProductionDrawDetailRow.merged(group),
      );
    }
    return result;
  }

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
      tableKey:
          'features.warehouse.widgets.production_draw_detail_table.ProductionDrawDetailTable.build.1',
      key: const Key('production-draw-detail-table'),
      primary: primary,
      enableTextSelection: !_capturesWeight && issueQtyControllers == null,
      rowKeyOf: (row) => row.stableRowKey,
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
          key: 'issueStatus',
          label: '状态',
          width: 72,
          value: (row) => row.isMergedGroup
              ? (row.group!
                            .map((r) => r.document!.issueStatus)
                            .toSet()
                            .length ==
                        1
                    ? drawIssueStatusLabel(
                        row.group!.first.document!.issueStatus,
                      )
                    : '—')
              : row.discovery == null
              ? drawIssueStatusLabel(row.document!.issueStatus)
              : '待确认出库',
        ),
        MasterColumnDef(
          // 2026-09-25 单号列统一：明细就地排序+按值筛选。
          key: 'billNo',
          sortable: true,
          filterFromRows: true,
          label: '领料单号',
          width: 160,
          value: (row) => row.isMergedGroup
              ? '${row.group!.length} 张单'
              : _numberLabel(row.document?.billNo),
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
          value: (row) => row.isMergedGroup
              ? names.goods(row.group!.first.item!.goodsId)
              : row.discovery?.label('goodsName') ??
                    names.goods(row.item!.goodsId),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 120,
          value: (row) => row.isMergedGroup
              ? names.goodsInfo(row.group!.first.item!.goodsId)?.code ?? '—'
              : row.discovery?.label('goodsCode') ??
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
          value: (row) => row.isMergedGroup
              ? names.color(row.group!.first.item!.colorId)
              : row.discovery?.label('colorName') ??
                    names.color(row.item!.colorId),
        ),
        MasterColumnDef(
          key: 'warehouse',
          label: discoveryRows.isEmpty ? '仓库' : '仓库 *',
          width: discoveryRows.isEmpty ? 160 : 200,
          value: (row) => row.isMergedGroup
              ? _joinedOrDash(
                  row.group!.map(
                    (r) => names.warehouse(r.document!.warehouseId),
                  ),
                )
              : row.discovery?.label('warehouseName') ??
                    names.warehouse(row.document!.warehouseId),
          cellBuilder: (context, row) => row.isMergedGroup
              ? Text(
                  _joinedOrDash(
                    row.group!.map(
                      (r) => names.warehouse(r.document!.warehouseId),
                    ),
                  ),
                )
              : row.discovery == null
              ? Text(names.warehouse(row.document!.warehouseId))
              : _discoveryWarehouseCell(context, row.discovery!),
        ),
        MasterColumnDef(
          key: 'department',
          label: '领料车间',
          width: 150,
          value: (row) => row.isMergedGroup
              ? _joinedOrDash(
                  row.group!.map(
                    (r) => names.department(r.document!.departmentId),
                  ),
                )
              : row.discovery?.request.workshopName ??
                    names.department(row.document!.departmentId),
        ),
        // 姓名由详情接口随单返回(workerName): 单张详情/批量出库页都不再预加载员工档案,
        // 仓库/车间账号没有 employee:view 也能看到是谁来领料。
        MasterColumnDef(
          key: 'worker',
          label: '领料负责人',
          width: 140,
          value: (row) => row.isMergedGroup
              ? _joinedOrDash(
                  row.group!.map(
                    (r) => names.employeeOr(
                      r.document!.workerName,
                      r.document!.workerId,
                    ),
                  ),
                )
              : row.discovery == null
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
          value: (row) => row.isMergedGroup
              ? '—'
              : row.discovery?.label('stockPlace') ??
                    (row.item!.place?.trim().isNotEmpty == true
                        ? row.item!.place!
                        : names.goodsInfo(row.item!.goodsId)?.stockPlace ??
                              '—'),
        ),
        // 2026-10-10「数量 + 单位」内联口径：单位列删除，只读数量直接带单位、
        // 输入格单位显示在 suffixText；各数量列宽 +35 补单位占位。
        MasterColumnDef(
          key: 'qty',
          label: discoveryRows.isEmpty ? '应领数量' : '应领数量 *',
          width: discoveryRows.isEmpty ? 140 : 215,
          type: 'number',
          value: (row) => row.isMergedGroup
              ? _mergedQty(row.group!, (item) => item.qty ?? 0, _unitOf(row))
              : row.discovery == null
              ? formatQtyWithUnit(
                  row.item!.qty ?? 0,
                  _unitOf(row),
                  maxDecimals: 4,
                )
              : row.discovery!.quantity.text,
          exactValueOf: (row) => row.isMergedGroup
              ? _mergedExactQty(row.group!, (item) => item.qty)
              : row.discovery?.quantity.text ?? row.item?.qty?.toString(),
          exactListenableOf: (row) => row.discovery?.quantity,
          cellBuilder: (context, row) => row.isMergedGroup
              ? Text(
                  _mergedQty(row.group!, (item) => item.qty ?? 0, _unitOf(row)),
                )
              : row.discovery == null
              ? Text(
                  formatQtyWithUnit(
                    row.item!.qty ?? 0,
                    _unitOf(row),
                    maxDecimals: 4,
                  ),
                )
              : _discoveryQuantityCell(context, row.discovery!),
        ),
        MasterColumnDef(
          key: 'issuedQty',
          label: '已出库',
          width: 140,
          type: 'number',
          value: (row) => row.isMergedGroup
              ? _mergedQty(
                  row.group!,
                  (item) => item.issuedQty ?? 0,
                  _unitOf(row),
                )
              : row.discovery == null
              ? formatQtyWithUnit(
                  row.item!.issuedQty ?? 0,
                  _unitOf(row),
                  maxDecimals: 4,
                )
              : formatQtyWithUnit(0, _unitOf(row)),
          exactValueOf: (row) => row.isMergedGroup
              ? _mergedExactQty(row.group!, (item) => item.issuedQty)
              : row.discovery == null
              ? row.item?.issuedQty?.toString()
              : '0',
        ),
        // 已出库重量 = 本行各轮出库流水重量合计 (服务端按流水算, 估算带「≈」)。
        MasterColumnDef(
          key: 'issuedWeight',
          label: '已出库重量',
          width: 120,
          type: 'number',
          info: '各轮出库实称/分摊的重量合计(已扣取消出库); 「≈」为按库存均重或单重估算。',
          value: (row) => _issuedWeightText(row.item),
          exactValueOf: (row) => (row.item?.issuedQty ?? 0) > 0
              ? row.item?.issuedWeightKg?.toString()
              : null,
          cellBuilder: (context, row) {
            final item = row.item;
            if (item == null || (item.issuedQty ?? 0) <= 0) {
              return const Text('—');
            }
            return WeightText(
              kg: item.issuedWeightKg,
              estimated: item.issuedWeightEstimated,
            );
          },
        ),
        MasterColumnDef(
          key: 'remainingQty',
          label: '待出库',
          width: 140,
          type: 'number',
          value: (row) => row.isMergedGroup
              ? _mergedQty(
                  row.group!,
                  (item) => item.remainingQty,
                  _unitOf(row),
                )
              : row.discovery == null
              ? formatQtyWithUnit(
                  row.item!.remainingQty,
                  _unitOf(row),
                  maxDecimals: 4,
                )
              : '待确认',
          exactValueOf: (row) => row.isMergedGroup
              ? _mergedExactQty(row.group!, (item) => item.remainingQty)
              : row.discovery == null
              ? row.item?.remainingQty.toString()
              : null,
        ),
        // 批量整单出库没有「本次出库」列: 本次重量紧跟「待出库」(本次 = 待出库)。
        if (issueQtyControllers == null) ...weightColumns,
        // 2026-09-12：本次出库数量与行备注在表格内编辑(默认=待出库)，
        // 出库按钮只弹总结确认——弹窗里不再改数字、不再传附件。
        if (issueQtyControllers != null) ...[
          MasterColumnDef(
            key: 'issueQty',
            label: '本次出库',
            width: 155,
            type: 'number',
            value: (row) => issueQtyControllers![row.item?.id]?.text ?? '',
            exactValueOf: (row) => issueQtyControllers![row.item?.id]?.text,
            exactListenableOf: (row) => issueQtyControllers![row.item?.id],
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
                  unitName: _unitOf(row),
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
          key: 'planNo',
          label: '生产计划',
          width: 170,
          value: (row) => row.isMergedGroup
              ? _joinedOrDash(row.group!.map((r) => r.document?.planNo ?? ''))
              : row.discovery?.request.planNo ?? row.document?.planNo ?? '—',
          cellBuilder: (context, row) => row.isMergedGroup
              ? Text(
                  _joinedOrDash(
                    row.group!.map((r) => r.document?.planNo ?? ''),
                  ),
                )
              : _sourceLink(
                  context,
                  row.discovery?.request.planNo ?? row.document?.planNo,
                  row.document?.sourcePlanId == null
                      ? null
                      : RoutePath.productionPlanDetail(
                          row.document!.sourcePlanId!,
                        ),
                ),
        ),
        MasterColumnDef(
          key: 'sourceDocNo',
          label: '来源',
          width: 170,
          value: (row) => row.isMergedGroup
              ? '—'
              : row.discovery?.request.segmentCode ??
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
            exactValueOf: (row) => row.item?.weight?.toString(),
            cellBuilder: (context, row) => row.item?.weight == null
                ? const Text('—')
                : WeightText(kg: row.item!.weight),
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
              // 2026-10-06 行高统一口径：紧凑 IconButton（不超过同行输入格的 39 高）。
              return Wrap(
                children: [
                  IconButton(
                    key: ValueKey('draw-discovery-split-${discovery.id}'),
                    tooltip: '拆分到其他发料仓',
                    onPressed: issueSaving || onSplitDiscoveryRow == null
                        ? null
                        : () => onSplitDiscoveryRow!(discovery),
                    style: IconButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    iconSize: 16,
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
                    style: IconButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    iconSize: 16,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              );
            },
          ),
        ],
      ],
      items: viewRows,
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

  /// 可按称重推算的数量格: 推算值黄框预填, ⓘ 说明推算区间;
  /// [unitName] 是单位后缀 (单位列删除后随输入框显示, 2026-10-10 口径)。
  Widget _autofillQuantityField(
    BuildContext context, {
    required Key key,
    required UtenAutofillTextController controller,
    required OutboundWeightEntry? weight,
    required bool enabled,
    bool readOnly = false,
    String? hintText,
    String? unitName,
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
        decoration: applyAutofillHint(
          applyRequiredEmpty(
            UtenInputDecoration(
              InputDecoration(
                isDense: true,
                hintText: hintText,
                error: error,
                suffixText: unitName,
              ),
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
    unitName: (row.values['unitName'] as String?)?.trim(),
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
    // 2026-10-06 行高统一口径：关掉 TextButton 的 min40（子级 InputDecorator
    // 自带必填红框/错误提示，不能换成纯文字动作），高度交给 isDense 装饰。
    style: TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    ),
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
    // 2026-10-06 行高统一口径：单号链接用单行文字动作，不再用 min40 的
    // TextButton 把行撑高（批量出库只读行回到 37 单行文本基线）。
    return UtenTableCellAction(
      label: label,
      tooltip: label,
      onPressed: () => context.push(path),
    );
  }

  /// 行单位名（2026-10-10「数量 + 单位」内联口径，单位列已删除）：合并行取组首
  /// 行单位，发现行取申请行快照 values['unitName']；names.unit 未加载返回「—」，
  /// 拼装前滤掉，避免出现「5 —」。
  String? _unitOf(ProductionDrawDetailRow row) {
    final String? name;
    if (row.isMergedGroup) {
      name = names.unit(row.group!.first.item!.unitId);
    } else if (row.discovery != null) {
      name = (row.discovery!.values['unitName'] as String?)?.trim();
    } else {
      name = names.unit(row.item?.unitId);
    }
    return name == null || name.isEmpty || name == '—' ? null : name;
  }

  /// 合并行数量合计（组员逐行取数相加），单位随数量内联 (2026-10-10 口径)。
  static String? _mergedExactQty(
    List<ProductionDrawDetailRow> group,
    double? Function(StockDocItem) pick,
  ) => financeExactSumTexts([
    for (final row in group)
      row.item == null ? null : pick(row.item!)?.toString(),
  ]);

  static String _mergedQty(
    List<ProductionDrawDetailRow> group,
    double Function(StockDocItem) pick,
    String? unit,
  ) => formatQtyWithUnit(
    group.fold<double>(
      0,
      (acc, row) => acc + (row.item == null ? 0 : pick(row.item!)),
    ),
    unit,
    maxDecimals: 4,
  );

  /// 合并行多值摘要：单值原样、多值「N 个」、空「—」。
  static String _joinedOrDash(Iterable<String> values) {
    final list = values.where((v) => v.isNotEmpty && v != '—').toSet().toList();
    if (list.isEmpty) return '—';
    return list.length == 1 ? list.single : '${list.length} 个';
  }

  static String _numberLabel(String? number) =>
      number?.trim().isNotEmpty == true ? number!.trim() : '—';
}
