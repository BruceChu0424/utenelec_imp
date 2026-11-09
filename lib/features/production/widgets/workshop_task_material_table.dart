import '../../../core/formatters/exact_number_text.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/task_material_cards.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_execution_workbench_repository.dart';

const _warehouseAvailableLabel = '本任务仓库可用';
const _warehouseAvailableHint = '含本任务专属来源和扣除其他占用及安全库存后可用的公共数量。齐套生产在到齐前不预留。';

/// 逐种物料状态 → 档位（ADR-169 锚定，与流程词表/物料摘要同口径）：
/// 已领到车间=绿（就绪）；已备好可领=蓝（去领料动作）；已申请待仓库发料=
/// 青绿（仓库处理中·他方执行）；备料中=灰（无动作无异常的中性等待）；
/// 缺（等到货/等委外回厂/等自制子件）=红——料没到齐，本任务不能齐套开工
/// （用户口径「不能往下=红」）；等计划下单另行盖品红（分类强调）。
UtenStatusBadgeType workshopMaterialBadgeType(
  ProductionWorkshopTaskMaterial row,
) => row.waitingForPlanning
    ? UtenStatusBadgeType.fuchsia
    : switch (row.state) {
        'ISSUED' => UtenStatusBadgeType.success,
        'DRAWABLE' => UtenStatusBadgeType.info,
        'AWAITING_WAREHOUSE' => UtenStatusBadgeType.accent,
        'PREPARING' => UtenStatusBadgeType.neutral,
        'SHORT' || 'SHORT_MAKE' => UtenStatusBadgeType.danger,
        _ => UtenStatusBadgeType.neutral,
      };

String _qty(double value, String? unit, String? unitFallback) {
  final text = value
      .toExactString(minimumFractionDigits: 4)
      .replaceFirst(RegExp(r'\.?0+$'), '');
  final suffix = unit ?? unitFallback ?? '';
  return suffix.isEmpty ? text : '$text $suffix';
}

/// 车间一种物料 → 公共物料卡片（[TaskMaterialCards]，与委外任务中心物料弹窗同一组件）。
TaskMaterialEntry workshopTaskMaterialEntry(
  ProductionWorkshopTaskMaterial row, {
  String? unitFallback,
}) {
  String qty(double value) => _qty(value, row.unitName, unitFallback);
  return TaskMaterialEntry(
    id: row.demandId,
    goodsName: row.goodsName,
    goodsCode: row.goodsCode,
    colorName: row.colorName,
    stateLabel: row.stateLabel,
    stateType: workshopMaterialBadgeType(row),
    stateIcon: row.waitingForPlanning ? Icons.campaign_rounded : null,
    sourceLabel: row.sourceLabel,
    headline: [
      TaskMaterialFact('需求', qty(row.requiredQty)),
      TaskMaterialFact('已领', qty(row.issuedQty)),
      TaskMaterialFact('可领', qty(row.requestableQty), selectionOnly: true),
      TaskMaterialFact('缺口', qty(row.shortageQty), error: row.shortageQty > 0),
    ],
    details: [
      TaskMaterialFact(
        _warehouseAvailableLabel,
        qty(row.warehouseAvailableQty),
        hint: _warehouseAvailableHint,
      ),
      TaskMaterialFact('已预留', qty(row.reservedQty)),
      TaskMaterialFact('待仓库发料', qty(row.requestedUnissuedQty)),
      TaskMaterialFact('可申请领料', qty(row.requestableQty)),
      if (row.supplyRoute == 'MAKE') ...[
        TaskMaterialFact('直送已交接', qty(row.directReceivedQty)),
        TaskMaterialFact('直送可分配', qty(row.directAvailableQty)),
        TaskMaterialFact('直送料待投入', qty(row.lineSidePendingQty)),
      ],
      if (row.planningGapQty > 0)
        TaskMaterialFact('计划未下单', qty(row.planningGapQty)),
    ],
    footnotes: [
      ('来源 ${row.sourceLabel}', true),
      if (row.producingSegmentsLabel?.isNotEmpty == true)
        ('子件工单 ${row.producingSegmentsLabel}', false),
    ],
  );
}

/// 车间任务详情里的「每种物料」表（ADR-095，2026-09-20 用户口径「车间内流转的
/// 货品数量怎么统计、显示在哪里」）：需求 / 本任务仓库可用 / 直送已交接 / 已领 / 缺口 /
/// 状态 / 子件工单，全部来自服务端逐种事实，页面不做任何推算。
class WorkshopTaskMaterialTable extends ConsumerStatefulWidget {
  const WorkshopTaskMaterialTable({
    super.key,
    required this.segmentId,
    this.unitFallback,
    this.compact = false,
    this.materialRows,
    this.showAllInitially = false,
    this.compactScrollable = false,
    this.selectableDemandIds = const {},
    this.selectedDemandIds = const {},
    this.onSelectedDemandIdsChanged,
  });

  final String segmentId;
  final String? unitFallback;

  /// 任务弹窗默认只展示物料身份、状态和关键数量，其余到料事实逐行展开。
  final bool compact;

  /// A containing read scope may load facts together with a draw preview.
  final List<ProductionWorkshopTaskMaterial>? materialRows;
  final bool showAllInitially;

  /// For a bounded dialog viewport, mount compact rows only as they enter view.
  final bool compactScrollable;
  final Set<String> selectableDemandIds;
  final Set<String> selectedDemandIds;
  final ValueChanged<Set<String>>? onSelectedDemandIdsChanged;

  @override
  ConsumerState<WorkshopTaskMaterialTable> createState() =>
      _WorkshopTaskMaterialTableState();
}

class _WorkshopTaskMaterialTableState
    extends ConsumerState<WorkshopTaskMaterialTable> {
  late Future<List<ProductionWorkshopTaskMaterial>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant WorkshopTaskMaterialTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segmentId != widget.segmentId ||
        !listEquals(oldWidget.materialRows, widget.materialRows)) {
      _future = _load();
    }
  }

  Future<List<ProductionWorkshopTaskMaterial>> _load() =>
      widget.materialRows != null
      ? Future.value(widget.materialRows!)
      : ref
            .read(productionExecutionWorkbenchRepositoryProvider)
            .workshopTaskMaterials(widget.segmentId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<ProductionWorkshopTaskMaterial>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: UtenSpacing.s12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Row(
            children: [
              Expanded(
                child: Text(
                  '物料明细加载失败',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              TextButton(
                key: const Key('workshop-task-material-retry'),
                onPressed: () {
                  final future = _load();
                  setState(() {
                    _future = future;
                  });
                },
                child: const Text('重试'),
              ),
            ],
          );
        }
        final rows = snapshot.data ?? const [];
        if (rows.isEmpty) {
          return Text(
            '本任务不需要领用物料',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        }
        if (widget.compact) {
          // 换任务时展开状态随卡片列表一起重置。
          return TaskMaterialCards(
            key: ValueKey('workshop-task-material-cards-${widget.segmentId}'),
            entries: [
              for (final row in rows)
                workshopTaskMaterialEntry(
                  row,
                  unitFallback: widget.unitFallback,
                ),
            ],
            keyPrefix: 'workshop-task-material',
            selectKeyPrefix: 'workshop-material-select',
            scrollable: widget.compactScrollable,
            showAllInitially: widget.showAllInitially,
            selectableIds: widget.selectableDemandIds,
            selectedIds: widget.selectedDemandIds,
            onSelectedIdsChanged: widget.onSelectedDemandIdsChanged,
          );
        }
        final small = theme.textTheme.bodySmall;
        String qty(ProductionWorkshopTaskMaterial row, double value) =>
            _qty(value, row.unitName, widget.unitFallback);
        return MasterDataTableView<ProductionWorkshopTaskMaterial>(
          expensiveRowMounts: false,
          key: const Key('workshop-task-material-table'),
          tableKey: 'production.workshopTask.materials',
          embedded: true,
          rowKeyOf: (row) => row.demandId,
          selectable: widget.onSelectedDemandIdsChanged != null,
          idOf: (row) => widget.selectableDemandIds.contains(row.demandId)
              ? row.demandId
              : null,
          selectedIds: widget.selectedDemandIds,
          onSelectedIdsChanged: widget.onSelectedDemandIdsChanged,
          platformBinding: PlatformTableBinding(
            tableKey: 'production.workshopTask.materials',
            scope: 'view_production',
            recordIdOf: (_) => null,
            factValuesOf: (row) => {
              'requiredQty': row.requiredQty.toString(),
              'warehouseAvailableQty': row.warehouseAvailableQty.toString(),
              'directReceivedQty': row.supplyRoute == 'MAKE'
                  ? row.directReceivedQty.toString()
                  : null,
              'issuedQty': row.issuedQty.toString(),
              'shortageQty': row.shortageQty.toString(),
            },
          ),
          columns: [
            MasterColumnDef(
              key: 'state',
              label: '状态',
              width: 72,
              filterFromRows: true,
              facetSearchEnabled: true,
              value: (row) => row.stateLabel,
              cellBuilder: (_, row) => Tooltip(
                message: row.waitingForPlanning
                    ? (row.planningRouteConfirmed
                          ? '计划还差 ${qty(row, row.planningGapQty)} 没下单，可以在任务详情里点「催计划」提醒计划员'
                          : '计划还没定这种料怎么供（采购 / 委外 / 自制），还差 ${qty(row, row.planningGapQty)}')
                    : row.stateLabel,
                child: TaskMaterialStateCell(
                  key: ValueKey('workshop-task-material-state-${row.demandId}'),
                  label: row.stateLabel,
                  icon: row.waitingForPlanning ? Icons.campaign_rounded : null,
                  type: workshopMaterialBadgeType(row),
                ),
              ),
            ),
            MasterColumnDef(
              key: 'goodsName',
              label: '物料',
              width: 180,
              value: (row) => row.goodsName,
            ),
            MasterColumnDef(
              key: 'goodsCode',
              label: '编号',
              width: 130,
              value: (row) => row.goodsCode,
            ),
            MasterColumnDef(
              key: 'colorName',
              label: '颜色',
              width: 90,
              value: (row) => row.colorName,
            ),
            MasterColumnDef(
              key: 'source',
              label: '来源',
              width: 110,
              columnSearchEnabled: false,
              filterFromRows: true,
              facetSearchEnabled: true,
              value: (row) => row.sourceLabel,
            ),
            MasterColumnDef(
              key: 'requiredQty',
              label: '需求',
              width: 130,
              type: 'number',
              sortable: true,
              filterFromRows: true,
              facetSearchEnabled: true,
              exactValueOf: (row) => row.requiredQty.toString(),
              value: (row) => qty(row, row.requiredQty),
            ),
            MasterColumnDef(
              key: 'warehouseAvailableQty',
              label: _warehouseAvailableLabel,
              info: _warehouseAvailableHint,
              width: 168,
              type: 'number',
              sortable: true,
              filterFromRows: true,
              facetSearchEnabled: true,
              exactValueOf: (row) => row.warehouseAvailableQty.toString(),
              value: (row) => qty(row, row.warehouseAvailableQty),
              cellBuilder: (_, row) => Tooltip(
                message: '本任务已预留 ${qty(row, row.reservedQty)}',
                child: Text(qty(row, row.warehouseAvailableQty)),
              ),
            ),
            MasterColumnDef(
              key: 'directReceivedQty',
              label: '直送已交接',
              width: 140,
              type: 'number',
              sortable: true,
              filterFromRows: true,
              facetSearchEnabled: true,
              exactValueOf: (row) => row.supplyRoute == 'MAKE'
                  ? row.directReceivedQty.toString()
                  : null,
              value: (row) => row.supplyRoute == 'MAKE'
                  ? qty(row, row.directReceivedQty)
                  : null,
              cellBuilder: (_, row) => Tooltip(
                message: row.supplyRoute == 'MAKE'
                    ? '自制子件工单已直送到本车间的数量；其中尚未分配给本任务 ${qty(row, row.directAvailableQty)}'
                    : '采购/委外物料一律经仓库领料，不走车间直送',
                child: Text(
                  row.supplyRoute == 'MAKE'
                      ? qty(row, row.directReceivedQty)
                      : '—',
                ),
              ),
            ),
            MasterColumnDef(
              key: 'issuedQty',
              label: '已领到车间',
              width: 140,
              type: 'number',
              sortable: true,
              filterFromRows: true,
              facetSearchEnabled: true,
              exactValueOf: (row) => row.issuedQty.toString(),
              value: (row) => qty(row, row.issuedQty),
              cellBuilder: (_, row) => Tooltip(
                message:
                    '净实领（实领减退回、损耗与待退冻结）；待仓库发 ${qty(row, row.requestedUnissuedQty)}，可提交领料 ${qty(row, row.requestableQty)}${row.lineSidePendingQty > 0 ? '，直送料待开工投入 ${qty(row, row.lineSidePendingQty)}' : ''}',
                child: Text(qty(row, row.issuedQty)),
              ),
            ),
            MasterColumnDef(
              key: 'shortageQty',
              label: '缺口',
              width: 130,
              type: 'number',
              sortable: true,
              filterFromRows: true,
              facetSearchEnabled: true,
              exactValueOf: (row) =>
                  row.shortageQty > 0 ? row.shortageQty.toString() : null,
              value: (row) =>
                  row.shortageQty > 0 ? qty(row, row.shortageQty) : null,
              cellBuilder: (_, row) => Text(
                row.shortageQty > 0 ? qty(row, row.shortageQty) : '—',
                style: row.shortageQty > 0
                    ? small?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      )
                    : null,
              ),
            ),
            MasterColumnDef(
              key: 'producingSegments',
              label: '子件工单',
              width: 180,
              value: (row) => row.producingSegmentsLabel,
            ),
          ],
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
        );
      },
    );
  }
}
