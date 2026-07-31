import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/payroll_batch.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollReviewPage extends ConsumerStatefulWidget {
  const PayrollReviewPage({super.key});

  @override
  ConsumerState<PayrollReviewPage> createState() => _PayrollReviewPageState();
}

class _PayrollReviewPageState extends ConsumerState<PayrollReviewPage> {
  String? _selectedId;
  bool _acting = false;

  @override
  Widget build(BuildContext context) {
    final batchesAsync = ref.watch(payrollBatchListProvider);
    final batches = batchesAsync.valueOrNull?.items ?? const <PayrollBatch>[];
    final selectedId = batches.any((batch) => batch.id == _selectedId)
        ? _selectedId
        : (batches.isEmpty ? null : batches.first.id);
    final detailAsync = selectedId == null
        ? null
        : ref.watch(payrollBatchDetailProvider(selectedId));
    final selectedBatch = detailAsync?.valueOrNull;
    final permissions = ref.watch(currentPermissionsProvider);

    Widget body = batchesAsync.when(
      loading: () => const UtenSkeletonList(),
      error: (error, _) => UtenEmpty.error(
        message: '加载工资批次失败：$error',
        actionLabel: '重试',
        onAction: () => ref.invalidate(payrollBatchListProvider),
      ),
      data: (page) {
        final loadedBatches = page.items;
        if (loadedBatches.isEmpty) {
          return const UtenEmpty(
            icon: Icons.payments_outlined,
            message: '暂无工资批次',
          );
        }
        return Column(
          children: [
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                itemCount: loadedBatches.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: UtenSpacing.s8),
                itemBuilder: (context, index) {
                  final batch = loadedBatches[index];
                  return _BatchChip(
                    batch: batch,
                    selected: batch.id == selectedId,
                    onTap: () => setState(() => _selectedId = batch.id),
                  );
                },
              ),
            ),
            if (page.totalPages > 1)
              UtenGridPager(
                currentPage: page.page,
                totalPages: page.totalPages,
                totalItems: page.total,
                onPrev: !batchesAsync.isLoading && page.page > 1
                    ? () => ref
                          .read(payrollBatchListProvider.notifier)
                          .previousPage()
                    : null,
                onNext: !batchesAsync.isLoading && page.page < page.totalPages
                    ? () =>
                          ref.read(payrollBatchListProvider.notifier).nextPage()
                    : null,
              ),
            const Divider(height: 1),
            Expanded(
              child: detailAsync!.when(
                loading: () => const UtenSkeletonList(),
                error: (error, _) => UtenEmpty.error(
                  message: '加载批次详情失败：$error',
                  actionLabel: '重试',
                  onAction: () =>
                      ref.invalidate(payrollBatchDetailProvider(selectedId!)),
                ),
                data: (batch) => RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(payrollBatchDetailProvider(batch.id));
                    await ref.read(payrollBatchDetailProvider(batch.id).future);
                  },
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s16,
                    ),
                    child: _BatchDetail(batch: batch),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '工资批次审核', showBackButton: true),
      bottomNavigationBar: selectedBatch == null
          ? null
          : _actionBar(selectedBatch, permissions),
      body: body,
    );
  }

  Widget? _actionBar(PayrollBatch batch, Set<String> permissions) {
    if (batch.status == PayrollBatchStatus.draft &&
        permissions.contains(Perm.payrollGenerate)) {
      return UtenBottomActionBar(
        child: UtenButton(
          isExpanded: true,
          isLoading: _acting,
          icon: Icons.send_outlined,
          onPressed: _acting ? null : () => _act(batch, _BatchAction.submit),
          child: const Text('提交审核'),
        ),
      );
    }
    if (batch.status == PayrollBatchStatus.submitted &&
        permissions.contains(Perm.payrollReview)) {
      return UtenBottomActionBar(
        child: Row(
          children: [
            UtenButton(
              type: UtenButtonType.ghost,
              isLoading: _acting,
              icon: Icons.close_rounded,
              onPressed: _acting
                  ? null
                  : () => _act(batch, _BatchAction.reject),
              child: const Text('驳回'),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: UtenButton(
                isExpanded: true,
                isLoading: _acting,
                icon: Icons.check_rounded,
                onPressed: _acting
                    ? null
                    : () => _act(batch, _BatchAction.approve),
                child: const Text('审核通过'),
              ),
            ),
          ],
        ),
      );
    }
    if (batch.status == PayrollBatchStatus.approved &&
        permissions.contains(Perm.payrollPublish)) {
      return UtenBottomActionBar(
        child: UtenButton(
          isExpanded: true,
          isLoading: _acting,
          icon: Icons.publish_outlined,
          onPressed: _acting ? null : () => _act(batch, _BatchAction.publish),
          child: const Text('发布工资条'),
        ),
      );
    }
    return null;
  }

  Future<void> _act(PayrollBatch batch, _BatchAction action) async {
    if (action == _BatchAction.submit && batch.slips.isEmpty) {
      context.appError('服务器未返回员工工资明细，不能提交空批次');
      return;
    }

    if (action == _BatchAction.publish) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认发布工资条？'),
          content: Text(
            '发布后，${batch.headcount} 名员工将可以查看 '
            '${batch.periodLabel} 的工资条。请确认审核结果与金额无误。',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认发布'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    String? reason;
    if (action == _BatchAction.reject) {
      reason = await _askRejectReason();
      if (reason == null) return;
    }

    setState(() => _acting = true);
    try {
      switch (action) {
        case _BatchAction.submit:
          await submitPayrollBatch(ref, batch.id);
        case _BatchAction.approve:
          await approvePayrollBatch(ref, batch.id);
        case _BatchAction.reject:
          await rejectPayrollBatch(ref, batch.id, reason!);
        case _BatchAction.publish:
          await publishPayrollBatch(ref, batch.id);
      }
      if (!mounted) return;
      context.appSuccess(switch (action) {
        _BatchAction.submit => '工资批次已提交审核',
        _BatchAction.approve => '工资批次已审核通过',
        _BatchAction.reject => '工资批次已驳回',
        _BatchAction.publish => '工资条已发布',
      });
    } catch (error) {
      if (mounted) context.appError('操作失败：$error');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<String?> _askRejectReason() async {
    final controller = TextEditingController();
    String? validationError;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('驳回工资批次'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: '驳回原因',
              errorText: validationError,
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => validationError = '请填写驳回原因');
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('确认驳回'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return reason;
  }
}

enum _BatchAction { submit, approve, reject, publish }

class _BatchChip extends StatelessWidget {
  const _BatchChip({
    required this.batch,
    required this.selected,
    required this.onTap,
  });

  final PayrollBatch batch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.1)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${batch.periodLabel} · ${batch.scopeLabel}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              Text(
                '${batch.status.label} · ${batch.headcount}人',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchDetail extends StatelessWidget {
  const _BatchDetail({required this.batch});

  final PayrollBatch batch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenCard(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Column(
            children: [
              UtenInfoRow(label: '工资月份', value: batch.periodLabel),
              UtenInfoRow(label: '生成范围', value: batch.scopeLabel),
              UtenInfoRow(
                label: '状态',
                value: null,
                valueWidget: Align(
                  alignment: Alignment.centerRight,
                  child: UtenStatusBadge(
                    label: batch.status.label,
                    type: _batchBadge(batch.status),
                  ),
                ),
              ),
              UtenInfoRow(label: '员工人数', value: '${batch.headcount} 人'),
              UtenInfoRow(
                label: '应发合计',
                value: '¥ ${batch.grossIncome.toStringAsFixed(2)}',
              ),
              UtenInfoRow(
                label: '扣除合计',
                value: '¥ ${batch.totalDeduction.toStringAsFixed(2)}',
              ),
              UtenInfoRow(
                label: '实发合计',
                value: '¥ ${batch.netIncome.toStringAsFixed(2)}',
                isImportant: true,
                showDivider: false,
              ),
            ],
          ),
        ),
        if (batch.rejectReason != null &&
            batch.rejectReason!.trim().isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          UtenCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '驳回原因：${batch.rejectReason}',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s16),
        const UtenSectionHeader(title: '员工工资明细'),
        const SizedBox(height: UtenSpacing.s8),
        if (batch.slips.isEmpty)
          const UtenEmpty(message: '服务器未返回该批次的员工明细')
        else
          UtenCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: (batch.slips.length * 64.0)
                  .clamp(128.0, 480.0)
                  .toDouble(),
              child: ListView.separated(
                itemCount: batch.slips.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
                itemBuilder: (context, index) =>
                    _SlipRow(slip: batch.slips[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _SlipRow extends StatelessWidget {
  const _SlipRow({required this.slip});

  final PayrollSlip slip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = slip.employeeName.trim().isEmpty
        ? '?'
        : slip.employeeName.characters.first;
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: UtenColors.teal500,
        child: Text(initial, style: const TextStyle(color: Colors.white)),
      ),
      title: Text('${slip.employeeName}（${slip.employeeCode}）'),
      subtitle: Text(
        '应发 ¥${slip.grossIncome.toStringAsFixed(2)} · '
        '扣除 ¥${slip.totalDeduction.toStringAsFixed(2)}',
      ),
      trailing: Text(
        '¥ ${slip.netIncome.toStringAsFixed(2)}',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.primary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

UtenStatusBadgeType _batchBadge(PayrollBatchStatus status) => switch (status) {
  PayrollBatchStatus.draft => UtenStatusBadgeType.neutral,
  PayrollBatchStatus.submitted => UtenStatusBadgeType.warning,
  PayrollBatchStatus.approved => UtenStatusBadgeType.accent,
  PayrollBatchStatus.rejected => UtenStatusBadgeType.danger,
  PayrollBatchStatus.published => UtenStatusBadgeType.success,
};
