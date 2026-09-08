// 委外任务中心「产品进度」弹窗（2026-09-06：计划委外申请并入任务中心后，
// 双击行不再跳详情页，就地看着这个产品走到哪一步）。
//
// 两种形态：
//  - 待生产合成行（SubcontractMakeTask，有子层先自制、未全部通知）：展示车间
//    进度时间线（等待安排生产 → 生产中 → 已完工入库·待通知委外 → 已通知委外）
//    与需求/已产/已通知账本；
//  - 已下达申请行（WAITING_ORDER）：前置生产已完成，展示从申请到入库的
//    全链路时间线，当前停在「待生成委外订货单」，并提供「查看申请单」深链
//    （经路由权限与服务端对象门禁）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../operations_workbench/models/operations_workbench.dart';
import '../../production/models/production_material_analysis.dart';
import '../../production/widgets/subcontract_make_task_tile.dart';
import '../providers/subcontract_task_count_provider.dart';

class _ProgressStep {
  const _ProgressStep(this.label, {this.done = false, this.current = false});
  final String label;
  final bool done;
  final bool current;
}

Future<void> showSubcontractApplicationProgressDialog(
  BuildContext context, {
  SubcontractMakeTask? makeTask,
  OperationsWorkbenchTask? task,
  Future<void> Function()? onNotified,
}) {
  assert((makeTask != null) != (task != null), '二选一：合成行或申请行');
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: _ProgressDialogBody(
            makeTask: makeTask,
            task: task,
            onNotified: onNotified,
          ),
        ),
      ),
    ),
  );
}

class _ProgressDialogBody extends ConsumerWidget {
  const _ProgressDialogBody({this.makeTask, this.task, this.onNotified});

  final SubcontractMakeTask? makeTask;
  final OperationsWorkbenchTask? task;
  final Future<void> Function()? onNotified;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mt = makeTask;
    final appTask = task;
    final permissions = ref.watch(currentPermissionsProvider);
    final canNotify =
        ref.watch(isSuperAdminProvider) ||
        (permissions.contains(Perm.productionMaterialAnalysisView) &&
            permissions.contains(Perm.productionMaterialAnalysisNotify));
    final title = mt != null
        ? (mt.goodsLabel.isEmpty ? '待生产委外件' : mt.goodsLabel)
        : (appTask!.isDocumentGrouped
              ? appTask.goodsSummaryLabel
              : appTask.goodsName);
    final steps = mt != null ? _makeSteps(mt) : _applicationSteps();
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.timeline_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '产品进度 · $title',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          if (mt != null) ...[
            _facts(theme, [
              ('需求量', _qty(mt.requiredQty, mt.unitName)),
              ('已完工入库', _qty(mt.producedQty, mt.unitName)),
              ('已通知委外', _qty(mt.notifiedQty, mt.unitName)),
              ('待通知可用量', _qty(mt.availableQty, mt.unitName)),
              if ((mt.warehouseName ?? '').isNotEmpty)
                ('目标仓库', mt.warehouseName!),
              if ((mt.needDate ?? '').isNotEmpty) ('需求日期', mt.needDate!),
              if ((mt.updatedAt ?? '').isNotEmpty) ('更新时间', mt.updatedAt!),
            ]),
            if (mt.workshopStatus == 'CANCELLED') ...[
              const SizedBox(height: UtenSpacing.s8),
              _notice(
                theme,
                color: theme.colorScheme.error,
                text: '该委外件的生产任务已取消。',
              ),
            ],
          ] else ...[
            _facts(theme, [
              if ((appTask!.actionDocument?.number ?? '').isNotEmpty)
                ('委外申请号', appTask.actionDocument!.number),
              ('来源计划', appTask.planNo),
              ('待下单量', appTask.quantityText),
              if ((appTask.needDate ?? '').isNotEmpty)
                ('需求日期', appTask.needDate!),
            ]),
          ],
          const SizedBox(height: UtenSpacing.s12),
          // 快递式追踪（与 MaterialSupplyProgressDialog 同口径）：最新进展在最
          // 上面、最早完成的步骤沉底——打开就能看到当前停在哪一步，不用往下翻
          //（2026-09-06 用户口径：最上面=最后完成的步骤，下面=最先的）。
          _timeline(theme, steps.reversed.toList()),
          if (appTask != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            _notice(
              theme,
              color: theme.colorScheme.tertiary,
              text:
                  '生成委外订货单后的进度（财务审核、目标件出仓、加工、回厂 IQC 与入库）'
                  '在「委外订货与全链路」双击订货单查看。',
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (mt != null &&
                  canNotify &&
                  mt.availableQty > 0 &&
                  mt.allows('NOTIFY_SUBCONTRACT')) ...[
                UtenActionButton(
                  key: const Key('subcontract-make-notify-action'),
                  icon: Icons.send_rounded,
                  label: Text(
                    AppLocalizations.of(context).materialTaskSubcontract,
                  ),
                  onAction: () async {
                    final notified = await showSubcontractMakeNotify(
                      context,
                      ref,
                      mt,
                    );
                    if (!notified || !context.mounted) return;
                    ref.invalidate(subcontractTaskCountProvider);
                    await onNotified?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                const SizedBox(width: UtenSpacing.s8),
              ],
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              if (appTask != null &&
                  (appTask.actionDocument?.canView ?? false) &&
                  (appTask.actionDocument?.number ?? '').isNotEmpty) ...[
                const SizedBox(width: UtenSpacing.s8),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final path = appTask.actionDocument!.path;
                    Navigator.of(context).pop();
                    // 经路由深链只读申请详情（权限与对象门禁照常生效）。
                    context.push(path);
                  },
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('查看申请单'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  List<_ProgressStep> _makeSteps(SubcontractMakeTask mt) {
    switch (mt.workshopStatus ?? '') {
      case 'NOTIFYING_WORKSHOP':
        return const [
          _ProgressStep('正在等待安排生产', current: true),
          _ProgressStep('生产中'),
          _ProgressStep('已完工入库·待通知委外'),
          _ProgressStep('已通知委外·生成申请'),
        ];
      case 'PRODUCED':
        return const [
          _ProgressStep('正在等待安排生产', done: true),
          _ProgressStep('生产中', done: true),
          _ProgressStep('已完工入库·待通知委外', current: true),
          _ProgressStep('已通知委外·生成申请'),
        ];
      case 'FULLY_NOTIFIED':
        return const [
          _ProgressStep('正在等待安排生产', done: true),
          _ProgressStep('生产中', done: true),
          _ProgressStep('已完工入库·待通知委外', done: true),
          _ProgressStep('已通知委外·生成申请', done: true),
        ];
      case 'CANCELLED':
        return const [
          _ProgressStep('正在等待安排生产', done: true),
          _ProgressStep('生产中'),
          _ProgressStep('已完工入库·待通知委外'),
          _ProgressStep('已通知委外·生成申请'),
        ];
      // WAITING_MATERIALS / IN_PRODUCTION / 未知编码一律按生产中展示。
      default:
        return const [
          _ProgressStep('正在等待安排生产', done: true),
          _ProgressStep('生产中', current: true),
          _ProgressStep('已完工入库·待通知委外'),
          _ProgressStep('已通知委外·生成申请'),
        ];
    }
  }

  List<_ProgressStep> _applicationSteps() => const [
    _ProgressStep('前置生产完成', done: true),
    _ProgressStep('计划已下达申请', done: true),
    _ProgressStep('待生成委外订货单', current: true),
    _ProgressStep('财务审核'),
    _ProgressStep('目标件出仓·加工商加工'),
    _ProgressStep('回厂 IQC·入库结案'),
  ];

  String _qty(num value, String? unit) {
    final text = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    final unitName = unit?.trim() ?? '';
    return unitName.isEmpty ? text : '$text $unitName';
  }

  Widget _facts(ThemeData theme, List<(String, String)> entries) {
    return Wrap(
      spacing: UtenSpacing.s16,
      runSpacing: UtenSpacing.s4,
      children: [
        for (final (label, value) in entries)
          Text.rich(
            TextSpan(
              text: '$label ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              children: [
                TextSpan(
                  text: value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _timeline(ThemeData theme, List<_ProgressStep> steps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, step) in steps.indexed)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: step.done || step.current
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                        border: Border.all(
                          color: step.current
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: step.current ? 3 : 1,
                        ),
                      ),
                    ),
                    if (index != steps.length - 1)
                      Expanded(
                        child: Container(
                          width: 2,
                          color: step.done
                              ? theme.colorScheme.primary.withValues(alpha: 0.6)
                              : theme.colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: UtenSpacing.s12),
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                  child: Text(
                    step.current ? '${step.label}（当前）' : step.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: step.current ? FontWeight.w700 : null,
                      color: step.done || step.current
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _notice(
    ThemeData theme, {
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }
}
