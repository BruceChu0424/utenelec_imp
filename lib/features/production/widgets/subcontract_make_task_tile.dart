import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../core/network/api_exception.dart';
import '../../production/models/production_material_analysis.dart';
import '../../production/repositories/production_repository.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/theme/uten_colors.dart';

/// V458 委外件前置自制任务行（公共组件）。
///
/// 物料分析准备页与委外准备中心共用：展示 produced/notified/available
/// 权威数量与状态徽标；可通知时提供「通知委外」分批入口。
/// 服务端 allowedActions 与页面权限共同决定按钮可用性。
class SubcontractMakeTaskTile extends ConsumerStatefulWidget {
  const SubcontractMakeTaskTile({
    super.key,
    required this.task,
    required this.canNotify,
    this.onOpenAnalysis,
    this.onNotified,
    this.compact = false,
  });

  final SubcontractMakeTask task;
  final bool canNotify;
  final VoidCallback? onOpenAnalysis;
  final VoidCallback? onNotified;
  final bool compact;

  @override
  ConsumerState<SubcontractMakeTaskTile> createState() =>
      _SubcontractMakeTaskTileState();
}

class _SubcontractMakeTaskTileState
    extends ConsumerState<SubcontractMakeTaskTile> {
  bool _notifying = false;

  String _qtyText(double qty) {
    final fixed = qty.toStringAsFixed(4);
    final trimmed = fixed.replaceAll(RegExp(r'0+$'), '').replaceAll(
      RegExp(r'\.$'),
      '',
    );
    return trimmed.isEmpty ? '0' : trimmed;
  }

  String get _statusLabel {
    if (widget.task.status == 'CANCELLED') return '已取消';
    if (widget.task.availableQty > 0) {
      return widget.task.producedQty < widget.task.requiredQty
          ? '自制中·可分批通知'
          : '满批待通知';
    }
    if (widget.task.requiredQty > 0 &&
        widget.task.notifiedQty >= widget.task.requiredQty) {
      return '已全部通知委外';
    }
    return '前置自制中';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = widget.task;
    final canNotify =
        widget.canNotify && task.allows('NOTIFY_SUBCONTRACT') && !_notifying;
    final statusColor = switch (_statusLabel) {
      '已取消' => theme.colorScheme.outline,
      '已全部通知委外' => UtenColors.success,
      '自制中·可分批通知' || '满批待通知' => theme.colorScheme.tertiary,
      _ => theme.colorScheme.primary,
    };
    return Padding(
      key: ValueKey('subcontract-make-task-${task.taskId}'),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      task.goodsLabel,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: UtenRadius.smAll,
                      ),
                      child: Text(
                        _statusLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor,
                        ),
                      ),
                    ),
                    if (task.itemSourceRef case final sourceRef?)
                      Text(
                        sourceRef,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s2),
                Text(
                  '需求 ${_qtyText(task.requiredQty)} · 已产 '
                  '${_qtyText(task.producedQty)} · 已通知 '
                  '${_qtyText(task.notifiedQty)} · 可通知 '
                  '${_qtyText(task.availableQty)}'
                  '${task.unitName == null ? '' : ' ${task.unitName}'}'
                  '${task.warehouseName == null ? '' : ' · ${task.warehouseName}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onOpenAnalysis != null && widget.compact)
            Padding(
              padding: const EdgeInsets.only(left: UtenSpacing.s8),
              child: IconButton(
                tooltip: '打开物料分析',
                onPressed: widget.onOpenAnalysis,
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
              ),
            ),
          if (canNotify || _notifying)
            Padding(
              padding: const EdgeInsets.only(left: UtenSpacing.s8),
              child: _notifying
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : FilledButton.tonal(
                      key: ValueKey('subcontract-make-notify-${task.taskId}'),
                      onPressed: _showNotifyDialog,
                      child: Text('通知委外(${_qtyText(task.availableQty)})'),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _showNotifyDialog() async {
    final task = widget.task;
    final controller = TextEditingController(text: _qtyText(task.availableQty));
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('通知委外·${task.goodsLabel}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本次可通知 ${_qtyText(task.availableQty)}'
              '${task.unitName == null ? '' : ' ${task.unitName}'}'
              '（已产 ${_qtyText(task.producedQty)}，已通知 '
              '${_qtyText(task.notifiedQty)}）。\n'
              '确认后生成委外申请并通知委外部分解订货。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('subcontract-make-notify-qty'),
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '本次通知数量',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final qty = double.tryParse(controller.text.trim());
              if (qty == null || qty <= 0 || qty > task.availableQty) {
                dialogContext.appError('数量必须大于 0 且不超过可通知量');
                return;
              }
              Navigator.of(dialogContext).pop(qty);
            },
            child: const Text('确认通知'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _notifying = true);
    try {
      final notifyResult = await ref
          .read(productionPlanRepositoryProvider)
          .notifySubcontractMakeBatch(
            taskId: task.taskId,
            qty: result,
            idempotencyKey: businessIdempotencyKey(
              'subcontract-make-notify',
              [task.taskId, task.notifiedQty, result].join('|'),
            ),
          );
      if (!mounted) return;
      context.appSuccess(
        '已生成委外申请 ${notifyResult.applicationBillNo}（本批 '
        '${_qtyText(notifyResult.notifiedQty)}），委外部已收到通知',
      );
      widget.onNotified?.call();
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError('通知委外失败：${error.message}');
    } catch (error) {
      if (!mounted) return;
      context.appError('通知委外失败：$error');
    } finally {
      if (mounted) setState(() => _notifying = false);
    }
  }
}
