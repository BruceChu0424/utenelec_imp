// 委外任务中心「待处理」行双击弹窗：申请摘要 + 锁定原因（2026-10-08 改版）。
//
// 弹窗只回答两件事：这条申请现在什么情况（关键数量 + 数量归属），以及为什么
// (还)不能下单——锁行（等物料齐套 / 缺 BOM，ADR-143 §二.3 / ADR-156）顶部红框
// 写明原因。原 8 步流程时间线退役：下单后的全链路进度（领料发外 → 加工回厂 →
// 品质检验 → 仓库确认入仓 → 结案核销）在「委外订货与全链路」双击订货单查看。
// 可经「查看申请单」深链只读申请详情（经路由权限与服务端对象门禁）。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/subcontract_task_source.dart';
import '../../operations_workbench/models/operations_workbench.dart';

/// 等物料齐套的锁行说明（勾选位锁图标悬浮 / 弹窗红框 / 窄屏卡片提示同一句）。
const subcontractWaitingKitHint = '直属物料还没齐，委外价格每天不同，物料齐了才解锁下单';

/// 锁行原因：缺 BOM / 等物料齐套逐条说明，其余不可下单行给通用口径。
/// 表格勾选位锁图标悬浮、双击弹窗红框、窄屏卡片锁位共用。
String subcontractTaskLockReason(OperationsWorkbenchTask task) {
  if (task.isBomMissing) {
    final rd = task.rdTaskNo?.trim() ?? '';
    return rd.isEmpty
        ? '委外件还没有 BOM，没有直属物料可算；点状态列「通知研发完善」，研发保存 BOM 后自动恢复可下单'
        : '委外件还没有 BOM，已通知研发完善($rd)；研发保存 BOM 后自动恢复可下单';
  }
  if (task.isWaitingKit) return subcontractWaitingKitHint;
  return '这条申请当前不能生成委外订货单';
}

Future<void> showSubcontractApplicationDetailDialog(
  BuildContext context, {
  required OperationsWorkbenchTask task,

  /// 行是否锁定（页内下单判定同源）。
  required bool locked,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        child: _ApplicationDetailBody(task: task, locked: locked),
      ),
    ),
  ),
);

class _ApplicationDetailBody extends StatelessWidget {
  const _ApplicationDetailBody({required this.task, required this.locked});

  final OperationsWorkbenchTask task;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = task.isDocumentGrouped
        ? task.goodsSummaryLabel
        : task.goodsName;
    final identity = task.isDocumentGrouped
        ? ''
        : [
            task.goodsCode,
            task.spec,
            task.colorName,
          ].where((part) => part.trim().isNotEmpty).join(' · ');
    final document = task.actionDocument;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '委外申请 · $title',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (identity.isNotEmpty)
                      Text(
                        identity,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (locked) ...[
            const SizedBox(height: UtenSpacing.s12),
            _LockNotice(reason: subcontractTaskLockReason(task)),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _openFact()),
              const SizedBox(width: UtenSpacing.s24),
              Expanded(child: _orderableFact()),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _facts(theme, [
            if ((document?.number ?? '').isNotEmpty)
              ('委外申请号', document!.number),
            ('来源计划', task.planNo),
            if ((task.needDate ?? '').isNotEmpty) ('需求日期', task.needDate!),
          ]),
          if (task.sources.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _SourceOwnership(sources: task.sources),
          ],
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

  /// 待下单量：单货品行 = 未下单数量 + 单位；归组行 = 待下单行数。
  Widget _openFact() {
    final (value, unit) = task.isDocumentGrouped
        ? ('${task.openLineCount}', '行待下单')
        : (formatWorkbenchQuantity(task.openQty), task.unitName.trim());
    return _QtyFact(
      label: '待下单量',
      value: value,
      unit: unit.isEmpty ? null : unit,
    );
  }

  /// 这次可下单(ADR-156，数量由服务端算好)：锁行为 0(红)；可部分下单带剩余；
  /// 缺 BOM / 非申请行没有物料可算，显示 —。
  Widget _orderableFact() {
    final orderable = task.orderableQty;
    if (orderable == null) {
      return const _QtyFact(label: '这次可下单', value: '—');
    }
    final unit = task.isDocumentGrouped ? '' : task.unitName.trim();
    final suffix = task.isKitPartial && !task.isDocumentGrouped
        ? '/ 剩余 ${formatWorkbenchQuantity(task.openQty)}'
              '${unit.isEmpty ? '' : ' $unit'}'
        : unit;
    return _QtyFact(
      label: '这次可下单',
      value: formatWorkbenchQuantity(orderable),
      unit: suffix.isEmpty ? null : suffix,
      danger: task.isWaitingKit,
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
}

/// 锁定原因红框：红底红字 + 锁图标，标题说明状态、正文说明原因与解锁条件。
class _LockNotice extends StatelessWidget {
  const _LockNotice({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.controlAll,
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '暂时不能下单',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 关键数量：标签弱化、数值放大（danger 时红色），单位/剩余说明跟在数值后小号显示。
class _QtyFact extends StatelessWidget {
  const _QtyFact({
    required this.label,
    required this.value,
    this.unit,
    this.danger = false,
  });

  final String label;
  final String value;
  final String? unit;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s2),
        Text.rich(
          TextSpan(
            text: value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: danger ? theme.colorScheme.error : null,
            ),
            children: [
              if (unit != null)
                TextSpan(
                  text: ' $unit',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
