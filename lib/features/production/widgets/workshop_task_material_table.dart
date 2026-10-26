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
    this.compact = false,
  });

  final String segmentId;
  final String? unitFallback;

  /// 任务弹窗默认只展示物料身份、状态和关键数量，其余到料事实逐行展开。
  final bool compact;

  @override
  ConsumerState<WorkshopTaskMaterialTable> createState() =>
      _WorkshopTaskMaterialTableState();
}

class _WorkshopTaskMaterialTableState
    extends ConsumerState<WorkshopTaskMaterialTable> {
  late Future<List<ProductionWorkshopTaskMaterial>> _future;
  final Set<String> _expandedDemandIds = {};
  bool _showAllMaterials = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant WorkshopTaskMaterialTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segmentId != widget.segmentId) {
      _expandedDemandIds.clear();
      _showAllMaterials = false;
      _future = _load();
    }
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
          final visibleRows = _showAllMaterials ? rows : rows.take(1).toList();
          return Column(
            key: const Key('workshop-task-material-table'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < visibleRows.length; index++) ...[
                if (index > 0) const SizedBox(height: UtenSpacing.s8),
                _compactRow(context, visibleRows[index]),
              ],
              if (rows.length > 1) ...[
                const SizedBox(height: UtenSpacing.s12),
                FilledButton.tonalIcon(
                  key: const Key('workshop-task-material-toggle-all'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, UtenSpacing.s48),
                  ),
                  onPressed: () => setState(() {
                    _showAllMaterials = !_showAllMaterials;
                    if (!_showAllMaterials) _expandedDemandIds.clear();
                  }),
                  icon: Icon(
                    _showAllMaterials
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _showAllMaterials ? '收起物料' : '展开查看全部物料（共 ${rows.length} 项）',
                  ),
                ),
              ],
            ],
          );
        }
        final small = theme.textTheme.bodySmall;
        return MasterDataTableView<ProductionWorkshopTaskMaterial>(
          expensiveRowMounts: false,
          key: const Key('workshop-task-material-table'),
          tableKey: 'production.workshopTask.materials',
          embedded: true,
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

  Widget _compactRow(BuildContext context, ProductionWorkshopTaskMaterial row) {
    final theme = Theme.of(context);
    final expanded = _expandedDemandIds.contains(row.demandId);
    final identity = [
      row.goodsCode,
      if (row.colorName?.trim().isNotEmpty == true) row.colorName!,
    ].where((value) => value.isNotEmpty).join(' · ');
    return Container(
      key: ValueKey('workshop-task-material-row-${row.demandId}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final identityBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.goodsName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (identity.isNotEmpty)
                        Text(
                          identity,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      WorkshopMaterialStateCell(
                        key: ValueKey(
                          'workshop-task-material-state-${row.demandId}',
                        ),
                        label: row.stateLabel,
                        icon: row.waitingForPlanning
                            ? Icons.campaign_rounded
                            : null,
                        type: row.waitingForPlanning
                            ? UtenStatusBadgeType.fuchsia
                            : _badgeType(row.state),
                      ),
                    ],
                  ),
                ],
              );
              final quantities = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _compactFact(context, '需求', row.requiredQty, row),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: _compactFact(context, '已领', row.issuedQty, row),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: _compactFact(
                      context,
                      '缺口',
                      row.shortageQty,
                      row,
                      error: row.shortageQty > 0,
                    ),
                  ),
                ],
              );
              final detailsButton = TextButton.icon(
                key: ValueKey('workshop-task-material-details-${row.demandId}'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                    vertical: UtenSpacing.s4,
                  ),
                ),
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedDemandIds.remove(row.demandId);
                  } else {
                    _expandedDemandIds.add(row.demandId);
                  }
                }),
                icon: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: const Text('到料明细'),
              );
              if (constraints.maxWidth >= 600) {
                return Row(
                  children: [
                    Expanded(flex: 4, child: identityBlock),
                    const SizedBox(width: UtenSpacing.s16),
                    Expanded(flex: 3, child: quantities),
                    const SizedBox(width: UtenSpacing.s8),
                    detailsButton,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identityBlock,
                  const SizedBox(height: UtenSpacing.s8),
                  quantities,
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: detailsButton,
                  ),
                ],
              );
            },
          ),
          if (expanded) ...[
            const Divider(height: UtenSpacing.s12),
            _arrivalDetails(context, row),
          ],
        ],
      ),
    );
  }

  Widget _compactFact(
    BuildContext context,
    String label,
    double value,
    ProductionWorkshopTaskMaterial row, {
    bool error = false,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: error
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s2),
        Text(
          _qty(value, row.unitName),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: error ? theme.colorScheme.error : null,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _arrivalDetails(
    BuildContext context,
    ProductionWorkshopTaskMaterial row,
  ) {
    final theme = Theme.of(context);
    final facts = <(String, String)>[
      ('仓库已到', _qty(row.warehouseAvailableQty, row.unitName)),
      ('已预留', _qty(row.reservedQty, row.unitName)),
      ('待仓库发料', _qty(row.requestedUnissuedQty, row.unitName)),
      ('可申请领料', _qty(row.requestableQty, row.unitName)),
      if (row.supplyRoute == 'MAKE') ...[
        ('直送已交接', _qty(row.directReceivedQty, row.unitName)),
        ('直送可分配', _qty(row.directAvailableQty, row.unitName)),
        ('直送料待投入', _qty(row.lineSidePendingQty, row.unitName)),
      ],
      if (row.planningGapQty > 0)
        ('计划未下单', _qty(row.planningGapQty, row.unitName)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s6,
          children: [
            for (final (label, value) in facts)
              Text('$label $value', style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '来源 ${row.sourceLabel}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (row.producingSegmentsLabel?.isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '子件工单 ${row.producingSegmentsLabel}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  /// 逐种物料状态 → 档位（ADR-169 锚定，与流程词表/物料摘要同口径）：
  /// 已领到车间=绿（就绪）；已备好可领=蓝（去领料动作）；已申请待仓库发料=
  /// 青绿（仓库处理中·他方执行）；备料中=灰（无动作无异常的中性等待）；
  /// 缺（等到货/等委外回厂/等自制子件）=红——料没到齐，本任务不能齐套开工
  /// （用户口径「不能往下=红」）；等计划下单由调用方另行盖品红（分类强调）。
  static UtenStatusBadgeType _badgeType(String state) => switch (state) {
    'ISSUED' => UtenStatusBadgeType.success,
    'DRAWABLE' => UtenStatusBadgeType.info,
    'AWAITING_WAREHOUSE' => UtenStatusBadgeType.accent,
    'PREPARING' => UtenStatusBadgeType.neutral,
    'SHORT' || 'SHORT_MAKE' => UtenStatusBadgeType.danger,
    _ => UtenStatusBadgeType.neutral,
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
    final (bg, fg) = resolveStatusBadgeColors(type);
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
