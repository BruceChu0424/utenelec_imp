// 工资批次审核页。
//
// 2026-09-09 表格化改版：批次 Chip 列表与摘要卡保留；_SlipRow ListView 员工明细
// → MasterDataTableView（列：工号/姓名/应发/扣减/实发，PayrollSlip 无部门字段故
// 不设部门列）。
// 2026-09-10 明细多选下线（审计 A2-payroll-review）：明细表曾开多选 +「批量通过(N)」，
// 但工资审核只有整批语义（后端仅 POST /batches/{id}/approve，无逐条审核 API），
// 勾选 1 条点「批量通过」实际整批通过 —— 语义误导，已删除 selectable/batchActionsBuilder。
// 审核入口唯一：底部 UtenBottomActionBar 的整批「审核通过 / 驳回」
//（均带 UtenReviewerResponsibilityNotice）；明细表退回只读浏览。
//
// 响应式：compact 由页面自套 UtenContentContainer；明细表为定高内滚（沿用旧版
// 高度钳制），窄屏横向滚动即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
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
            // 72：两行文案（期间·范围 + 状态·人数）在默认字号下约 36px，
            // 加行内边距后 64 会溢出 6px（2026-09-09 表格化改版时实测），放宽到 72。
            SizedBox(
              height: 72,
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

    if (action == _BatchAction.approve) {
      final confirmed = await showUtenReviewerConfirmDialog(
        context,
        title: '审核通过工资批次？',
        message: '审核通过后工资批次进入可发布状态，请确认工资明细和合计金额均已复核。',
        confirmLabel: '确认审核通过',
        actionLabel: '工资审核',
      );
      if (!confirmed || !mounted) return;
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
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const UtenReviewerResponsibilityNotice(
                  actionLabel: '工资审核驳回',
                  description: '确认后系统将记录当前审核员、驳回原因和时间，请对本次决定负责。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '驳回原因',
                      error: utenFieldError(validationError),
                    ),
                  ),
                ),
              ],
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
                style: theme.textTheme.titleSmall?.copyWith(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              Text(
                '${batch.status.label} · ${batch.headcount}人',
                style: theme.textTheme.labelSmall?.copyWith(
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
          // 明细表：定高内滚（沿用旧版高度钳制，多行时不与摘要卡争屏）。
          SizedBox(
            height: (batch.slips.length * 56.0).clamp(240.0, 480.0).toDouble(),
            child: MasterDataTableView<PayrollSlip>(
              key: const Key('payroll-review-slip-table'),
              columns: _slipColumns,
              items: batch.slips,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              // 明细无独立详情页，不接 onRowTap；审核只有整批语义（底部操作条），
              // 故明细表不开多选——勾选几条却整批生效是语义误导（2026-09-10 下线）。
              emptyMessage: '服务器未返回该批次的员工明细',
            ),
          ),
      ],
    );
  }
}

/// 员工工资明细列（以原 _SlipRow 字段为准：工号/姓名/应发/扣减/实发；
/// PayrollSlip 无部门字段，不设部门列）。
final List<MasterColumnDef<PayrollSlip>> _slipColumns = [
  MasterColumnDef(
    key: 'employeeCode',
    label: '工号',
    width: 100,
    value: (s) => s.employeeCode,
  ),
  MasterColumnDef(
    key: 'employeeName',
    label: '姓名',
    width: 120,
    value: (s) => s.employeeName,
  ),
  MasterColumnDef(
    key: 'grossIncome',
    label: '应发',
    width: 120,
    type: 'money',
    value: (s) => s.grossIncome.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'totalDeduction',
    label: '扣减',
    width: 120,
    type: 'money',
    value: (s) => s.totalDeduction.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'netIncome',
    label: '实发',
    width: 130,
    type: 'money',
    value: (s) => s.netIncome.toStringAsFixed(2),
  ),
];

UtenStatusBadgeType _batchBadge(PayrollBatchStatus status) => switch (status) {
  PayrollBatchStatus.draft => UtenStatusBadgeType.neutral,
  PayrollBatchStatus.submitted => UtenStatusBadgeType.warning,
  PayrollBatchStatus.approved => UtenStatusBadgeType.accent,
  PayrollBatchStatus.rejected => UtenStatusBadgeType.danger,
  PayrollBatchStatus.published => UtenStatusBadgeType.success,
};
