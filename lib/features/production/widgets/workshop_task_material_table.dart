import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_status_badge.dart';
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
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: const Key('workshop-task-material-table'),
            columnSpacing: UtenSpacing.s12,
            horizontalMargin: UtenSpacing.s8,
            headingRowHeight: 32,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 48,
            headingTextStyle: small?.copyWith(fontWeight: FontWeight.w700),
            dataTextStyle: small,
            columns: const [
              DataColumn(label: Text('物料')),
              DataColumn(label: Text('来源')),
              DataColumn(label: Text('需求'), numeric: true),
              DataColumn(label: Text('仓库已到'), numeric: true),
              DataColumn(label: Text('直送已交接'), numeric: true),
              DataColumn(label: Text('已领到车间'), numeric: true),
              DataColumn(label: Text('缺口'), numeric: true),
              DataColumn(label: Text('状态')),
              DataColumn(label: Text('子件工单')),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  key: ValueKey('workshop-task-material-${row.demandId}'),
                  cells: [
                    DataCell(
                      Text(
                        [
                          row.goodsName,
                          row.goodsCode,
                          if ((row.colorName ?? '').isNotEmpty) row.colorName!,
                        ].join(' · '),
                      ),
                    ),
                    DataCell(Text(row.sourceLabel)),
                    DataCell(Text(_qty(row.requiredQty, row.unitName))),
                    DataCell(
                      Tooltip(
                        message:
                            '仓库里当前可给本任务用的实物（专属来源 + 允许动用的公共库存），'
                            '齐套生产到齐前不预留，靠它看到货；已预留 ${_qty(row.reservedQty, row.unitName)}',
                        child: Text(
                          _qty(row.warehouseAvailableQty, row.unitName),
                        ),
                      ),
                    ),
                    DataCell(
                      Tooltip(
                        message: row.directSupply
                            ? '同车间子件工单已直送到本车间的数量；其中尚未分配给本任务 ${_qty(row.directAvailableQty, row.unitName)}'
                            : '本物料不走同车间直送',
                        child: Text(
                          row.directSupply
                              ? _qty(row.directReceivedQty, row.unitName)
                              : '—',
                        ),
                      ),
                    ),
                    DataCell(
                      Tooltip(
                        message:
                            '净实领（实领减退回、损耗与待退冻结）；'
                            '待仓库发 ${_qty(row.requestedUnissuedQty, row.unitName)}，'
                            '可提交领料 ${_qty(row.requestableQty, row.unitName)}'
                            '${row.lineSidePendingQty > 0 ? '，直送料待开工投入 ${_qty(row.lineSidePendingQty, row.unitName)}' : ''}',
                        child: Text(_qty(row.issuedQty, row.unitName)),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.shortageQty > 0
                            ? _qty(row.shortageQty, row.unitName)
                            : '—',
                        style: row.shortageQty > 0
                            ? small?.copyWith(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w700,
                              )
                            : null,
                      ),
                    ),
                    DataCell(
                      UtenStatusBadge(
                        label: row.stateLabel,
                        type: _badgeType(row.state),
                        size: UtenStatusBadgeSize.small,
                      ),
                    ),
                    DataCell(Text(row.producingSegmentsLabel ?? '—')),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  static UtenStatusBadgeType _badgeType(String state) => switch (state) {
    'ISSUED' => UtenStatusBadgeType.success,
    'DRAWABLE' => UtenStatusBadgeType.info,
    'AWAITING_WAREHOUSE' || 'PREPARING' => UtenStatusBadgeType.neutral,
    'SHORT' || 'SHORT_DIRECT' => UtenStatusBadgeType.warning,
    _ => UtenStatusBadgeType.accent,
  };

  String _qty(double value, String? unit) {
    final text = value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
    final suffix = unit ?? widget.unitFallback ?? '';
    return suffix.isEmpty ? text : '$text $suffix';
  }
}
