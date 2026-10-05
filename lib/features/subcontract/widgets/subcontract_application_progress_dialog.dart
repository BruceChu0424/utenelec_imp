// 委外任务中心「产品进度」弹窗（2026-09-06：计划委外申请并入任务中心后，
// 双击「待处理」行不再跳详情页，就地看着这个产品走到哪一步）。
//
// ADR-143 §4.6：委外与车间自制同构，只有一条线性时间线——
// 计划已下达申请 → 生成委外订货单(当前) → 财务审批 → 领料发外 → 加工回厂 →
// 品质检验 → 仓库确认入仓 → 结案核销。委外件的直属物料按各自路线准备，齐套后在
// 「领料」分段提交，委外商分批回厂。可再经「查看申请单」深链只读申请详情
// (经路由权限与服务端对象门禁)。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/subcontract_task_source.dart';
import '../../operations_workbench/models/operations_workbench.dart';

class _ProgressStep {
  const _ProgressStep(this.label, {this.done = false, this.current = false});
  final String label;
  final bool done;
  final bool current;
}

/// 申请行的进度步骤：申请已下达，正等委外生成订货单。
const _applicationSteps = <_ProgressStep>[
  _ProgressStep('计划已下达申请', done: true),
  _ProgressStep('生成委外订货单', current: true),
  _ProgressStep('财务审批'),
  _ProgressStep('领料发外'),
  _ProgressStep('加工回厂'),
  _ProgressStep('品质检验'),
  _ProgressStep('仓库确认入仓'),
  _ProgressStep('结案核销'),
];

Future<void> showSubcontractApplicationProgressDialog(
  BuildContext context, {
  required OperationsWorkbenchTask task,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(child: _ProgressDialogBody(task: task)),
    ),
  ),
);

class _ProgressDialogBody extends StatelessWidget {
  const _ProgressDialogBody({required this.task});

  final OperationsWorkbenchTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = task.isDocumentGrouped
        ? task.goodsSummaryLabel
        : task.goodsName;
    final document = task.actionDocument;
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
          _facts(theme, [
            if ((document?.number ?? '').isNotEmpty)
              ('委外申请号', document!.number),
            ('来源计划', task.planNo),
            ('待下单量', task.quantityText),
            if ((task.needDate ?? '').isNotEmpty) ('需求日期', task.needDate!),
          ]),
          if (task.sources.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _SourceOwnership(sources: task.sources),
          ],
          const SizedBox(height: UtenSpacing.s12),
          // 快递式追踪（与 MaterialSupplyProgressDialog 同口径）：最新进展在最
          // 上面、最早完成的步骤沉底——打开就能看到当前停在哪一步，不用往下翻
          //（2026-09-06 用户口径：最上面=最后完成的步骤，下面=最先的）。
          _timeline(theme, _applicationSteps.reversed.toList()),
          const SizedBox(height: UtenSpacing.s12),
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.10),
              borderRadius: UtenRadius.mdAll,
              border: Border.all(
                color: theme.colorScheme.tertiary.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              '生成委外订货单并经财务批准后，直属物料齐套即可在委外任务中心「领料」提交，'
              '仓库发出后委外商加工、分批回厂；回厂后的品质检验与入仓进度在'
              '「委外订货与全链路」双击订货单查看。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
              if ((document?.canView ?? false) &&
                  (document?.number ?? '').isNotEmpty) ...[
                const SizedBox(width: UtenSpacing.s8),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final path = document!.path;
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
}

class _SourceOwnership extends StatelessWidget {
  const _SourceOwnership({required this.sources});

  final List<SubcontractTaskSource> sources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('数量归属', style: theme.textTheme.titleSmall),
        for (final source in sources)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.isPublicStock ? '公共备货' : source.productLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (source.sourceNo.isNotEmpty)
                  Text(
                    '${source.sourceType == 'SALES_ORDER_ITEM' ? '销售订单' : '来源'} ${source.sourceNo}'
                    '${source.sourceLineNo == null ? '' : ' · 第${source.sourceLineNo}行'}',
                  ),
                Text(
                  '${source.materialLabel}：${_quantity(source.quantity)} ${source.unitName}',
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _quantity(num value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
