import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_execution_workbench_repository.dart';

/// 车间任务详情里的「每种物料」表（ADR-095，2026-09-20 用户口径「车间内流转的
/// 货品数量怎么统计、显示在哪里」）：需求 / 仓库已到 / 直送已交接 / 已领 / 缺口 /
/// 状态 / 子件工单，全部来自服务端逐种事实，页面不做任何推算。
class WorkshopTaskMaterialTable extends ConsumerStatefulWidget {
  const WorkshopTaskMaterialTable({
    super.key,
    required this.segmentId,
    this.unitFallback,
  });

  final String segmentId;
  final String? unitFallback;

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

  Future<List<ProductionWorkshopTaskMaterial>> _load() => ref
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
                onPressed: () => setState(() => _future = _load()),
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
        final small = theme.textTheme.bodySmall;
        return MasterDataTableView<ProductionWorkshopTaskMaterial>(
          key: const Key('workshop-task-material-table'),
          tableKey: 'production.workshopTask.materials',
          embedded: true,
          compactCards: true,
          rowKeyOf: (row) => row.demandId,
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
              value: (row) => row.stateLabel,
              cellBuilder: (_, row) => Tooltip(
                message: row.waitingForPlanning
                    ? (row.planningRouteConfirmed
                          ? '计划还差 ${_qty(row.planningGapQty, row.unitName)} 没下单，可以在任务详情里点「催计划」提醒计划员'
                          : '计划还没定这种料怎么供（采购 / 委外 / 自制），还差 ${_qty(row.planningGapQty, row.unitName)}')
                    : row.stateLabel,
                child: WorkshopMaterialStateCell(
                  key: ValueKey('workshop-task-material-state-${row.demandId}'),
                  label: row.stateLabel,
                  icon: row.waitingForPlanning ? Icons.campaign_rounded : null,
                  type: row.waitingForPlanning
                      ? UtenStatusBadgeType.fuchsia
                      : _badgeType(row.state),
                ),
              ),
            ),
            MasterColumnDef(
              key: 'goodsName',
              label: '物料',
              width: 180,
              // compactCards 卡片标题：状态列前置后名称列不再默认担任标题。
              cardRole: MasterColumnCardRole.title,
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
              value: (row) => row.sourceLabel,
            ),
            MasterColumnDef(
              key: 'requiredQty',
              label: '需求',
              width: 130,
              type: 'number',
              value: (row) => _qty(row.requiredQty, row.unitName),
            ),
            MasterColumnDef(
              key: 'warehouseAvailableQty',
              label: '仓库已到',
              width: 140,
              type: 'number',
              value: (row) => _qty(row.warehouseAvailableQty, row.unitName),
              cellBuilder: (_, row) => Tooltip(
                message:
                    '仓库里当前可给本任务用的实物（专属来源 + 允许动用的公共库存），齐套生产到齐前不预留；已预留 ${_qty(row.reservedQty, row.unitName)}',
                child: Text(_qty(row.warehouseAvailableQty, row.unitName)),
              ),
            ),
            MasterColumnDef(
              key: 'directReceivedQty',
              label: '直送已交接',
              width: 140,
              type: 'number',
              value: (row) => row.supplyRoute == 'MAKE'
                  ? _qty(row.directReceivedQty, row.unitName)
                  : null,
              cellBuilder: (_, row) => Tooltip(
                message: row.supplyRoute == 'MAKE'
                    ? '自制子件工单已直送到本车间的数量；其中尚未分配给本任务 ${_qty(row.directAvailableQty, row.unitName)}'
                    : '采购/委外物料一律经仓库领料，不走车间直送',
                child: Text(
                  row.supplyRoute == 'MAKE'
                      ? _qty(row.directReceivedQty, row.unitName)
                      : '—',
                ),
              ),
            ),
            MasterColumnDef(
              key: 'issuedQty',
              label: '已领到车间',
              width: 140,
              type: 'number',
              value: (row) => _qty(row.issuedQty, row.unitName),
              cellBuilder: (_, row) => Tooltip(
                message:
                    '净实领（实领减退回、损耗与待退冻结）；待仓库发 ${_qty(row.requestedUnissuedQty, row.unitName)}，可提交领料 ${_qty(row.requestableQty, row.unitName)}${row.lineSidePendingQty > 0 ? '，直送料待开工投入 ${_qty(row.lineSidePendingQty, row.unitName)}' : ''}',
                child: Text(_qty(row.issuedQty, row.unitName)),
              ),
            ),
            MasterColumnDef(
              key: 'shortageQty',
              label: '缺口',
              width: 130,
              type: 'number',
              value: (row) => row.shortageQty > 0
                  ? _qty(row.shortageQty, row.unitName)
                  : null,
              cellBuilder: (_, row) => Text(
                row.shortageQty > 0 ? _qty(row.shortageQty, row.unitName) : '—',
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

  static UtenStatusBadgeType _badgeType(String state) => switch (state) {
    'ISSUED' => UtenStatusBadgeType.success,
    'DRAWABLE' => UtenStatusBadgeType.info,
    'AWAITING_WAREHOUSE' || 'PREPARING' => UtenStatusBadgeType.neutral,
    'SHORT' || 'SHORT_MAKE' => UtenStatusBadgeType.warning,
    _ => UtenStatusBadgeType.accent,
  };

  String _qty(double value, String? unit) {
    final text = value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
    final suffix = unit ?? widget.unitFallback ?? '';
    return suffix.isEmpty ? text : '$text $suffix';
  }
}

/// 状态格：徽章同源底色铺满格内容区（2026-09-27 用户口径「格内胶囊改单元格
/// 背景色」；旧原生表没有 cellColor 通道，用带 0.5 描边的实色块等价实现，
/// 描边即用户口径「背景变色但边框要还在」）。文字用徽章深档色保证对比度，
/// 无圆角——读作整格着色而非胶囊。
class WorkshopMaterialStateCell extends StatelessWidget {
  const WorkshopMaterialStateCell({
    super.key,
    required this.label,
    required this.type,
    this.icon,
  });

  final String label;
  final UtenStatusBadgeType type;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = resolveStatusBadgeColors(
      type,
      theme.brightness == Brightness.dark,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
