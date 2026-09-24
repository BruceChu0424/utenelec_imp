// 报销详情页（申请人视角；审批人见 expense_approval_detail_page）
// 文档：docs/03-页面/报销详情页.md
//
// 2026-09-19 V608 全链路改版：对齐单据详情范式——卡片序 + 内嵌明细表
// （MasterDataTableView embedded + 合计条）+ 发票登记区（OCR/查重）+ 附件区 +
// 事件表真审批轨迹 + 打款信息回显（账户/费别/付款日期/关联财务单）+
// AppBar「打印报销单」（A4 费用报销单：单号/事由/明细/大写合计/五格签字栏）。
// 悬浮操作：DRAFT/REJECTED=删除/编辑/提交（重新提交）；SUBMITTED=撤回。
// 宽度口径：默认 1600 容器（明细表为主体）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/rmb_amount.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../providers/expense_settings_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import '../widgets/expense_claim_print.dart';
import '../widgets/expense_claim_timeline.dart';
import '../widgets/expense_invoice_section.dart';
import '../widgets/expense_submission_revision.dart';

class ExpenseDetailPage extends ConsumerStatefulWidget {
  const ExpenseDetailPage({super.key, required this.claimId});

  final String claimId;

  @override
  ConsumerState<ExpenseDetailPage> createState() => _ExpenseDetailPageState();
}

class _ExpenseDetailPageState extends ConsumerState<ExpenseDetailPage> {
  bool _acting = false;

  // 2026-09-22 全站表格滚动口径：明细表/发票表表头吸顶（stickyHeaderPinned），
  // 任一张表置顶后页面滚动条才显示（UtenGridPageScrollbar 门控）——
  // 表头未置顶不显示滚动条、表头随页滚走的旧形态退役。
  final ScrollController _pageScroll = ScrollController();
  final ValueNotifier<bool> _itemsPinned = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _invoicePinned = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _pageScroll.dispose();
    _itemsPinned.dispose();
    _invoicePinned.dispose();
    super.dispose();
  }

  ExpenseClaim? get _claim =>
      ref.read(expenseDetailProvider(widget.claimId)).valueOrNull;

  bool get _isOwner {
    final claim = _claim;
    final me = ref.read(sessionProvider).user?.employeeId;
    return claim != null &&
        me != null &&
        claim.applicantId == me &&
        ref.read(currentPermissionsProvider).contains(Perm.expenseApply);
  }

  Future<void> _run(
    String Function(ExpenseClaim claim) busyTitle,
    Future<void> Function() action,
  ) async {
    if (_acting) return;
    final claim = _claim;
    if (claim == null) return;
    setState(() => _acting = true);
    try {
      await action();
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _submitForApproval(ExpenseClaim claim) async {
    final l10n = AppLocalizations.of(context);
    if (claim.attachments.isEmpty ||
        claim.invoices.any((invoice) => invoice.attachmentId == null)) {
      context.appWarning(l10n.expenseFlowOriginalRequired);
      return;
    }
    final settings = await ref.read(expenseSettingsProvider.future);
    if (!mounted) return;
    if (claim.invoices.isEmpty &&
        (settings.requireInvoice || claim.remark?.trim().isNotEmpty != true)) {
      context.appWarning(
        settings.requireInvoice
            ? l10n.expenseFlowInvoiceRequiredGuide
            : l10n.expenseFlowNoInvoiceGuide,
      );
      return;
    }
    await submitExpense(ref, claim.id, expectedVersion: claim.version);
    if (mounted) {
      context.appSuccess(
        claim.status == ExpenseClaimStatus.rejected ? '已重新提交，等待审批' : '已提交，等待审批',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(expenseDetailProvider(widget.claimId));

    return Scaffold(
      appBar: UtenAppBar(
        title: '报销详情',
        showBackButton: true,
        actions: [
          detail.maybeWhen(
            data: (claim) => Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s8),
              child: UtenButton(
                key: const Key('expense-detail-print'),
                type: UtenButtonType.tonal,
                size: UtenButtonSize.small,
                icon: Icons.print_outlined,
                onPressed: () => showExpenseClaimPrintPreview(context, claim),
                child: const Text('打印报销单'),
              ),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: detail.when(
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败，请重试',
          onAction: () => ref.invalidate(expenseDetailProvider(widget.claimId)),
        ),
        data: (claim) => Stack(
          children: [
            Positioned.fill(
              child: UtenGridPageScrollbar(
                pinned: _itemsPinned,
                extraPinned: [_invoicePinned],
                controller: _pageScroll,
                child: UtenContentContainer(
                  child: ListView(
                    controller: _pageScroll,
                    padding: const EdgeInsets.fromLTRB(
                      0,
                      UtenSpacing.s16,
                      0,
                      UtenFloatingActionGroup.scrollClearance,
                    ),
                    children: [
                      _HeroCard(claim: claim),
                      if (claim.status == ExpenseClaimStatus.draft ||
                          claim.status == ExpenseClaimStatus.rejected)
                        Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s12),
                          child: Text(
                            AppLocalizations.of(
                              context,
                            ).expenseFlowInvoiceGuide,
                          ),
                        ),
                      const SizedBox(height: UtenSpacing.s16),
                      _infoCard(context, claim),
                      const SizedBox(height: UtenSpacing.s16),
                      ExpenseSubmissionChangeSummary(claim: claim),
                      _itemsSection(context, claim),
                      const SizedBox(height: UtenSpacing.s16),
                      _section(
                        context,
                        '发票登记',
                        ExpenseInvoiceSection(
                          claim: claim,
                          editable:
                              _isOwner &&
                              (claim.status == ExpenseClaimStatus.draft ||
                                  claim.status == ExpenseClaimStatus.rejected),
                          stickyHeaderPinned: _invoicePinned,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      _attachments(claim),
                      if (claim.status == ExpenseClaimStatus.paid) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        AttachmentSection(
                          ownerType: 'EXPENSE_PAYMENT_PROOF',
                          ownerId: claim.id,
                          title: AppLocalizations.of(
                            context,
                          ).expenseFlowPaymentProofs,
                          attachments: claim.paymentProofs,
                          ownerCanUpload: false,
                          ownerCanDelete: false,
                          onChanged: () =>
                              ref.invalidate(expenseDetailProvider(claim.id)),
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s16),
                      _section(
                        context,
                        '审批轨迹',
                        Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s16),
                            child: ExpenseClaimTimeline(claim: claim),
                          ),
                        ),
                      ),
                      if (claim.remark != null &&
                          claim.remark!.trim().isNotEmpty) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        _section(context, '备注', _remarkCard(context, claim)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_acting)
              const Positioned.fill(child: UtenBusyOverlay(title: '正在处理…')),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: detail.maybeWhen(
        data: (claim) => _actions(claim),
        orElse: () => null,
      ),
    );
  }

  Widget? _actions(ExpenseClaim claim) {
    if (!_isOwner) return null;
    final isDraft = claim.status == ExpenseClaimStatus.draft;
    final isRejected = claim.status == ExpenseClaimStatus.rejected;
    final inApproval =
        claim.status == ExpenseClaimStatus.submitted ||
        claim.status == ExpenseClaimStatus.reviewing;
    if (!isDraft && !isRejected && !inApproval) return null;

    return UtenFloatingActionGroup(
      children: [
        if (isDraft)
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.delete_outline_rounded,
            isLoading: _acting,
            onPressed: _acting ? null : () => _confirmDelete(claim),
            child: const Text('删除'),
          ),
        if (isDraft || isRejected)
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_outlined,
            onPressed: _acting
                ? null
                : () => context.push(RoutePath.expenseEdit(claim.id)),
            child: const Text('编辑'),
          ),
        if (isDraft || isRejected)
          UtenButton(
            key: const Key('expense-detail-submit'),
            size: UtenButtonSize.large,
            icon: isRejected ? Icons.replay_rounded : Icons.send_rounded,
            isLoading: _acting,
            onPressed: _acting
                ? null
                : () => _run((c) => '正在提交…', () => _submitForApproval(claim)),
            child: Text(isRejected ? '重新提交' : '提交审批'),
          )
        else if (inApproval)
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.undo_rounded,
            isLoading: _acting,
            onPressed: _acting
                ? null
                : () => _run((c) => '正在撤回…', () async {
                    await withdrawExpense(
                      ref,
                      claim.id,
                      expectedVersion: claim.version,
                    );
                    if (mounted) context.appSuccess('已撤回');
                  }),
            child: const Text('撤回'),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(ExpenseClaim claim) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除报销草稿？'),
        content: const Text('删除后无法恢复，请确认该草稿不再需要。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run((c) => '正在删除…', () async {
      await deleteExpense(ref, claim.id, expectedVersion: claim.version);
      if (mounted) {
        context.appSuccess('已删除');
        // 返回列表（pop 优先保住栈下来源；深链无栈才归位报销列表）。
        backTo(context, defaultPath: RouteName.expense);
      }
    });
  }

  // ---- 区块 -----------------------------------------------------------------

  Widget _section(BuildContext context, String title, Widget child) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        child,
      ],
    );
  }

  Widget _infoCard(BuildContext context, ExpenseClaim claim) {
    final rows = <(String, String)>[
      ('报销单号', claim.claimNo),
      ('申请人', claim.applicantName),
      ('部门', claim.departmentName ?? '—'),
      ('创建时间', _fmtDateTime(claim.createdAt)),
      if (claim.submittedAt != null) ('提交时间', _fmtDateTime(claim.submittedAt!)),
      if (claim.approvedAt != null)
        (
          '审批通过',
          '${claim.approvedByName ?? '—'} · ${_fmtDateTime(claim.approvedAt!)}',
        ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s8,
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        rows[i].$1,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rows[i].$2,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: rows[i].$1 == '报销单号'
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _itemsSection(BuildContext context, ExpenseClaim claim) {
    final revision = ExpenseSubmissionRevision.fromClaim(claim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          revision == null ? '报销明细 (${claim.items.length})' : '报销明细 · 修改对比',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (revision != null)
          ExpenseSubmissionItemTable(
            key: const Key('expense-detail-items-revision'),
            revision: revision,
            stickyHeaderPinned: _itemsPinned,
          )
        else
          MasterDataTableView<ExpenseItem>(
            key: const Key('expense-detail-items'),
            columns: _itemColumns,
            items: claim.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            embedded: true,
            stickyHeaderPinned: _itemsPinned,
            summaryBar: _itemsSummary(claim),
          ),
      ],
    );
  }

  Widget _itemsSummary(ExpenseClaim claim) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: UtenSpacing.s8,
      children: [
        Text(
          '共 ${claim.items.length} 项 · 合计 ',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          '¥ ${claim.totalAmount.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _attachments(ExpenseClaim claim) {
    final canManage =
        _isOwner &&
        (claim.status == ExpenseClaimStatus.draft ||
            claim.status == ExpenseClaimStatus.rejected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '附件 / 发票影像 (${claim.attachments.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        AttachmentSection(
          ownerType: 'EXPENSE_CLAIM',
          ownerId: claim.id,
          attachments: claim.attachments,
          ownerCanUpload: canManage,
          ownerCanDelete: canManage,
          onChanged: () => ref.invalidate(expenseDetailProvider(claim.id)),
        ),
      ],
    );
  }

  Widget _remarkCard(BuildContext context, ExpenseClaim claim) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Text(claim.remark!),
      ),
    );
  }
}

/// 头卡：状态徽章 + 金额大字 + 大写 + 驳回/打款横幅。
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.claim});

  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (expenseIsSubmittedModification(claim)) ...[
              Text(
                '报销单修改',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    claim.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                UtenStatusBadge(
                  label: claim.status.label,
                  type: _statusBadgeType(claim.status),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '¥ ${claim.totalAmount.toStringAsFixed(2)}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '${AppLocalizations.of(context).expenseFlowCapital}: ${rmbCapital(claim.totalAmount)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (claim.status == ExpenseClaimStatus.rejected &&
                claim.rejectReason != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _banner(
                context,
                icon: Icons.warning_amber_rounded,
                color: UtenColors.error,
                title:
                    '已驳回'
                    '${claim.rejectedByName == null ? '' : '（${claim.rejectedByName}）'}'
                    '：${claim.rejectReason}',
                hint: '点右下「编辑」修订后重新提交。',
              ),
            ],
            if (claim.status == ExpenseClaimStatus.paid) ...[
              const SizedBox(height: UtenSpacing.s12),
              _banner(
                context,
                icon: Icons.payments_outlined,
                color: UtenColors.teal600,
                title:
                    '已付款：'
                    '${claim.paymentAccountName ?? '—'} · '
                    '${claim.paymentExpenseStyleName ?? '—'} · '
                    '付款日期 ${claim.paymentDate == null ? '—' : _fmtDate(claim.paymentDate!)}',
                hint:
                    '出纳 ${claim.paidByName ?? '—'}'
                    '${claim.financeExpenseId == null ? '' : ' · 关联财务费用单已生成'}',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _banner(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    String? hint,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 2),
                  Text(hint, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final List<MasterColumnDef<ExpenseItem>> _itemColumns = [
  MasterColumnDef(
    key: 'category',
    label: '费用科目',
    width: 130,
    value: (item) => item.category.label,
  ),
  MasterColumnDef(
    key: 'date',
    label: '日期',
    width: 110,
    type: 'date',
    value: (item) => _fmtDate(item.date),
  ),
  MasterColumnDef(
    key: 'description',
    label: '说明',
    width: 260,
    value: (item) => item.description,
  ),
  MasterColumnDef(
    key: 'amount',
    label: '金额',
    width: 120,
    type: 'money',
    value: (item) => item.amount.toStringAsFixed(2),
  ),
];

UtenStatusBadgeType _statusBadgeType(ExpenseClaimStatus s) => switch (s) {
  ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
  ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
  ExpenseClaimStatus.reviewing => UtenStatusBadgeType.warning,
  ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
  ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
  ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
};

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fmtDateTime(DateTime t) =>
    '$_fmtDate(t) '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
