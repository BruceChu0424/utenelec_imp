import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_execution_workbench.dart';
import '../models/production_flow_stage.dart';
import 'production_flow_stage_cell.dart';

/// 展示任务事实；办理入口与权限由车间任务页提供，数量不在这里推算。
class WorkshopTaskDetailDialog extends StatelessWidget {
  const WorkshopTaskDetailDialog({
    super.key,
    required this.task,
    required this.stage,
    required this.routeBadge,
    required this.remainingReportQty,
    required this.draftReportedQty,
    required this.materialSummary,
    required this.materials,
    required this.actions,
    this.notices = const [],
  });

  final ProductionExecutionWorkbenchSegment task;
  final ProductionFlowStage stage;
  final Widget routeBadge;
  final double remainingReportQty;
  final double draftReportedQty;
  final Widget materialSummary;
  final List<Widget> materials;
  final List<Widget> actions;
  final List<Widget> notices;

  String _qty(double value) {
    final number = value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
    final unit = task.productUnitName?.trim() ?? '';
    return unit.isEmpty ? number : '$number $unit';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactActions = MediaQuery.sizeOf(context).width < 544;
    return AlertDialog(
      key: ValueKey('workshop-task-detail-${task.segmentId}'),
      insetPadding: const EdgeInsets.all(UtenSpacing.s16),
      title: const Text('车间任务详情'),
      content: SizedBox(
        width: 880,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                task.productName ?? '—',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text(task.segmentCode),
                  if (task.productCode?.isNotEmpty == true)
                    Text(task.productCode!),
                  if (task.productColorName?.isNotEmpty == true)
                    Text(task.productColorName!),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text(
                    '车间：${task.workshopName ?? '—'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    '负责人：${task.responsibleEmployeeName ?? '—'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text('计划：${task.planNo}', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  UtenStatusBadge(
                    label: stage.tone == ProductionFlowTone.active
                        ? '生产中'
                        : stage.label,
                    type: productionFlowBadgeType(stage),
                    icon: stage.icon,
                  ),
                  routeBadge,
                ],
              ),
              const SizedBox(height: UtenSpacing.s20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final metrics = [
                    ('planned', '计划数量', task.plannedQty),
                    ('reported', '已报工', task.reportedQty),
                    ('remaining', '待报工', remainingReportQty),
                    ('inbound', '计划实收', task.plannedInboundQty),
                  ];
                  var columns = constraints.maxWidth >= 720 ? 4 : 2;
                  // 大字号或长数量需要完整读作一个数，减少列数而不缩小字体。
                  for (final metric in metrics) {
                    final painter = TextPainter(
                      text: TextSpan(
                        text: _qty(metric.$3),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                    )..layout();
                    final neededWidth = painter.width + UtenSpacing.s12 * 2;
                    painter.dispose();
                    while (columns > 1 &&
                        neededWidth >
                            (constraints.maxWidth -
                                    UtenSpacing.s8 * (columns - 1)) /
                                columns) {
                      columns ~/= 2;
                    }
                  }
                  final width =
                      (constraints.maxWidth - UtenSpacing.s8 * (columns - 1)) /
                      columns;
                  return Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      for (final metric in metrics)
                        SizedBox(
                          width: width,
                          child: Container(
                            key: ValueKey(
                              'workshop-detail-quantity-${metric.$1}',
                            ),
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              borderRadius: UtenRadius.mdAll,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  metric.$2,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s4),
                                Text(
                                  _qty(metric.$3),
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color:
                                        metric.$1 == 'remaining' &&
                                            remainingReportQty > 0
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (draftReportedQty > 0 ||
                  task.actualSurplusReportedQty > 0 ||
                  task.actualSurplusInboundQty > 0) ...[
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    if (draftReportedQty > 0)
                      Text('草稿待审核 ${_qty(draftReportedQty)}'),
                    if (task.actualSurplusReportedQty > 0)
                      Text('其中超产 ${_qty(task.actualSurplusReportedQty)}'),
                    if (task.actualSurplusInboundQty > 0)
                      Text('公共超产实收 ${_qty(task.actualSurplusInboundQty)}'),
                  ],
                ),
              ],
              for (final notice in notices) ...[
                const SizedBox(height: UtenSpacing.s12),
                notice,
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                child: Divider(height: 1),
              ),
              Text(
                '物料',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              materialSummary,
              if (!task.zeroMaterial && task.materialKindCount > 0) ...[
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '已投料可产 ${_qty(task.materialSupportedOutputQty)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              for (final material in materials) ...[
                const SizedBox(height: UtenSpacing.s12),
                material,
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.all(UtenSpacing.s16),
      actions: [
        SizedBox(
          width: 880,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              for (final action in actions)
                if (compactActions && action is FilledButton)
                  SizedBox(
                    width:
                        MediaQuery.sizeOf(context).width - UtenSpacing.s16 * 4,
                    child: action,
                  )
                else
                  action,
            ],
          ),
        ),
      ],
    );
  }
}
