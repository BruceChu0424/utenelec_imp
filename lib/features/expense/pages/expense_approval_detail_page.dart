// 报销审批详情页（审批人/财务视角）
// 文档：docs/03-页面/报销审批详情页.md · 审批流见 docs/05-架构/全局机制.md §3.3
//
// 2026-09-19 V608 全链路改版：对齐财审页（finance_procurement_approval_review_page）
// 范式——卡片序 + 内嵌明细表（两位小数，修复原 toStringAsFixed(0) 抹零）+
// 发票登记只读核对 + 发票影像附件（审批人核对票据的核心场景，V608 补齐）+
// 事件表真审批轨迹 + 打款结果回显；右下 返回/驳回 danger/通过 success、
// APPROVED 态「登记付款」；AppBar 打印报销单。
// 宽度口径：默认 1600 容器。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/expense_invoice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/rmb_amount.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/task_claim_badge.dart';
import '../../../shared/widgets/task_claim_handle.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../models/expense_payment.dart';
import '../providers/expense_providers.dart';
import '../widgets/expense_claim_print.dart';
import '../widgets/expense_claim_timeline.dart';
import '../widgets/expense_invoice_section.dart';
import '../widgets/expense_submission_revision.dart';

class ExpenseApprovalDetailPage extends ConsumerStatefulWidget {
  const ExpenseApprovalDetailPage({super.key, required this.claimId});
  final String claimId;

  @override
  ConsumerState<ExpenseApprovalDetailPage> createState() =>
      _ExpenseApprovalDetailPageState();
}

class _ExpenseApprovalDetailPageState
    extends ConsumerState<ExpenseApprovalDetailPage> {
  final _comment = TextEditingController();
  bool _acting = false;

  // 2026-09-22 全站表格滚动口径：明细表/发票表表头吸顶，任一表置顶后才显示
  // 页面滚动条（UtenGridPageScrollbar 门控）。
  final ScrollController _pageScroll = ScrollController();
  final ValueNotifier<bool> _itemsPinned = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _invoicePinned = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _pageScroll.dispose();
    _itemsPinned.dispose();
    _invoicePinned.dispose();
    _comment.dispose();
    super.dispose();
  }

  ExpenseClaim? get _claim =>
      ref.read(expenseDetailProvider(widget.claimId)).valueOrNull;

  bool get _canApprove {
    final claim = _claim;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.expenseApprove) &&
        claim != null &&
        claim.applicantId != ref.read(sessionProvider).user?.employeeId &&
        (claim.status == ExpenseClaimStatus.submitted ||
            claim.status == ExpenseClaimStatus.reviewing);
  }

  bool get _canInspect {
    final permissions = ref.read(currentPermissionsProvider);
    return _canApprove &&
        permissions.contains(Perm.attachmentView) &&
        permissions.contains(Perm.attachmentDownload);
  }

  bool get _canPay {
    final claim = _claim;
    return ref.read(currentPermissionsProvider).contains(Perm.expensePay) &&
        claim?.status == ExpenseClaimStatus.approved &&
        claim?.applicantId != ref.read(sessionProvider).user?.employeeId &&
        claim?.approvedBy != ref.read(sessionProvider).user?.employeeId;
  }

  Future<void> _approve() async {
    if (_acting || !_canInspect) return;
    if (_claim?.invoices.any(
          (invoice) => invoice.checkState != ExpenseInvoiceCheckState.verified,
        ) ==
        true) {
      context.appWarning(
        AppLocalizations.of(context).expenseFlowVerifyBeforeApprove,
      );
      return;
    }
    setState(() => _acting = true);
    try {
      await approveExpense(ref, widget.claimId);
      if (mounted) {
        context.appSuccess('审批已通过');
        backTo(context, defaultPath: '/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _reject() async {
    final reason = _comment.text.trim();
    if (reason.isEmpty) {
      context.appError('请填写驳回原因');
      return;
    }
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await rejectExpense(ref, widget.claimId, reason);
      if (mounted) {
        context.appSuccess('报销单已驳回，等待申请人修订后重新提交');
        backTo(context, defaultPath: '/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _pay() async {
    final paymentClaim = _claim;
    if (_acting || paymentClaim == null) return;
    if (paymentClaim.paymentProofs.isEmpty) {
      context.appWarning(
        AppLocalizations.of(context).expenseFlowPaymentProofRequired,
      );
      return;
    }
    setState(() => _acting = true);
    try {
      final input = await showDialog<ExpensePaymentInput>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ExpensePaymentDialog(),
      );
      if (!mounted || input == null) return;
      await payExpense(
        ref,
        widget.claimId,
        input,
        expectedVersion: paymentClaim.version,
      );
      if (mounted) {
        context.appSuccess(AppLocalizations.of(context).expenseFlowPaymentDone);
        backTo(context, defaultPath: '/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(expenseDetailProvider(widget.claimId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: UtenAppBar(
        title: '报销审批详情',
        showBackButton: true,
        actions: [
          detail.maybeWhen(
            data: (claim) => Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s8),
              child: UtenButton(
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
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _canApprove
          ? TaskClaimHandle(
              targetType: 'EXPENSE_APPROVE',
              targetKey: widget.claimId,
              builder: (heldByMe, claim) {
                final blocked = !heldByMe && claim != null;
                return UtenFloatingActionGroup(
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.large,
                      onPressed: _acting
                          ? null
                          : () => backTo(
                              context,
                              defaultPath: '/expense/approval',
                            ),
                      child: const Text('返回'),
                    ),
                    UtenButton(
                      type: UtenButtonType.danger,
                      size: UtenButtonSize.large,
                      isLoading: _acting,
                      icon: Icons.close_rounded,
                      onPressed: (_acting || blocked) ? null : _reject,
                      child: const Text('驳回'),
                    ),
                    if (_canInspect)
                      UtenButton(
                        type: UtenButtonType.success,
                        size: UtenButtonSize.large,
                        isLoading: _acting,
                        icon: Icons.check_rounded,
                        onPressed: (_acting || blocked) ? null : _approve,
                        child: const Text('通过'),
                      ),
                  ],
                );
              },
            )
          : _canPay
          ? UtenFloatingActionGroup(
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
                  onPressed: _acting
                      ? null
                      : () => context.go('/expense/approval'),
                  child: const Text('返回'),
                ),
                UtenButton(
                  type: UtenButtonType.success,
                  size: UtenButtonSize.large,
                  isLoading: _acting,
                  icon: Icons.account_balance_wallet_outlined,
                  onPressed: _acting ? null : _pay,
                  child: Text(
                    AppLocalizations.of(context).expenseFlowPaymentRecord,
                  ),
                ),
              ],
            )
          : null,
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败，请重试',
          onAction: () => ref.invalidate(expenseDetailProvider(widget.claimId)),
        ),
        data: (claim) => UtenGridPageScrollbar(
          pinned: _itemsPinned,
          extraPinned: [_invoicePinned],
          controller: _pageScroll,
          child: UtenContentContainer(
            child: SingleChildScrollView(
              controller: _pageScroll,
              padding: const EdgeInsets.fromLTRB(
                0,
                UtenSpacing.s16,
                0,
                UtenFloatingActionGroup.scrollClearance,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Hero(claim: claim),
                  const SizedBox(height: UtenSpacing.s16),
                  _sectionTitle(theme, '申请信息'),
                  const SizedBox(height: UtenSpacing.s8),
                  _applicantCard(theme, claim),
                  const SizedBox(height: UtenSpacing.s20),
                  ExpenseSubmissionChangeSummary(claim: claim),
                  _itemsSection(theme, claim),
                  const SizedBox(height: UtenSpacing.s20),
                  _sectionTitle(theme, '发票登记'),
                  const SizedBox(height: UtenSpacing.s8),
                  ExpenseInvoiceSection(
                    claim: claim,
                    editable: false,
                    canVerify: _canInspect,
                    stickyHeaderPinned: _invoicePinned,
                  ),
                  const SizedBox(height: UtenSpacing.s20),
                  _sectionTitle(
                    theme,
                    '附件 / 发票影像 (${claim.attachments.length})',
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  AttachmentSection(
                    ownerType: 'EXPENSE_CLAIM',
                    ownerId: claim.id,
                    attachments: claim.attachments,
                    ownerCanUpload: false,
                    ownerCanDelete: false,
                    onChanged: () =>
                        ref.invalidate(expenseDetailProvider(claim.id)),
                  ),
                  const SizedBox(height: UtenSpacing.s20),
                  if (claim.status == ExpenseClaimStatus.approved ||
                      claim.status == ExpenseClaimStatus.paid) ...[
                    AttachmentSection(
                      ownerType: 'EXPENSE_PAYMENT_PROOF',
                      ownerId: claim.id,
                      title: AppLocalizations.of(
                        context,
                      ).expenseFlowPaymentProofs,
                      emptyHint: AppLocalizations.of(
                        context,
                      ).expenseFlowPaymentProofGuide,
                      attachments: claim.paymentProofs,
                      ownerCanUpload: _canPay,
                      ownerCanDelete: _canPay,
                      onChanged: () =>
                          ref.invalidate(expenseDetailProvider(claim.id)),
                    ),
                    const SizedBox(height: UtenSpacing.s20),
                  ],
                  _sectionTitle(theme, '审批轨迹'),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenCard(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: ExpenseClaimTimeline(claim: claim),
                    ),
                  ),
                  if (_canApprove && !_canInspect)
                    Text(
                      AppLocalizations.of(
                        context,
                      ).expenseFlowReadEvidenceRequired,
                    ),
                  if (_canApprove) ...[
                    const SizedBox(height: UtenSpacing.s20),
                    TaskClaimHandle(
                      targetType: 'EXPENSE_APPROVE',
                      targetKey: widget.claimId,
                      builder: (heldByMe, claim) {
                        final blocked = !heldByMe && claim != null;
                        if (!blocked) {
                          return const UtenReviewerResponsibilityNotice(
                            actionLabel: '报销审批',
                            description:
                                '点击通过或驳回后，系统将记录当前审核员及审批结果，请对本次决定负责。'
                                '请核对明细与发票（登记要素+影像）后再决定。',
                          );
                        }
                        return Row(
                          children: [
                            TaskClaimBadge(claim: claim),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '他人正在审批此单，请稍后再试',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w400),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: UtenSpacing.s20),
                    _sectionTitle(theme, '审批意见'),
                    const SizedBox(height: UtenSpacing.s8),
                    UtenCard(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      child: TextField(
                        controller: _comment,
                        maxLines: 3,
                        decoration: const UtenInputDecoration(
                          InputDecoration(
                            labelText: '驳回原因',
                            hintText: '驳回时必填，通过时不会提交',
                          ),
                          info: '驳回后申请人可修订重提：请写明修改要求（如缺票、金额不符）。',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _applicantCard(ThemeData theme, ExpenseClaim claim) {
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
    return UtenCard(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s8,
      ),
      child: Column(
        children: [
          row('报销单号', claim.claimNo),
          row('申请人', claim.applicantName),
          row('部门', claim.departmentName ?? '—'),
          row('标题', claim.title),
          if (claim.remark != null && claim.remark!.trim().isNotEmpty)
            row('备注', claim.remark!),
          row('提交时间', _fmt(claim.submittedAt ?? claim.createdAt)),
        ],
      ),
    );
  }

  Widget _itemsSection(ThemeData theme, ExpenseClaim claim) {
    final revision = ExpenseSubmissionRevision.fromClaim(claim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 2026-09-25 用户口径：纯计数标题「报销明细 (N)」退役；修改对比态标题保留。
        if (revision != null) ...[
          Text(
            '报销明细 · 修改对比',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (revision != null)
          ExpenseSubmissionItemTable(
            key: const Key('expense-approval-items-revision'),
            revision: revision,
            stickyHeaderPinned: _itemsPinned,
          )
        else
          MasterDataTableView<ExpenseItem>(
            key: const Key('expense-approval-items'),
            columns: _itemColumns,
            items: claim.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            embedded: true,
            stickyHeaderPinned: _itemsPinned,
            summaryBar: Wrap(
              alignment: WrapAlignment.end,
              spacing: UtenSpacing.s8,
              children: [
                Text(
                  '共 ${claim.items.length} 项 · 合计 ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '¥ ${claim.totalAmount.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
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

class _ExpensePaymentDialog extends ConsumerStatefulWidget {
  const _ExpensePaymentDialog();

  @override
  ConsumerState<_ExpensePaymentDialog> createState() =>
      _ExpensePaymentDialogState();
}

class _ExpensePaymentDialogState extends ConsumerState<_ExpensePaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _dateController;
  String? _accountId;
  String? _expenseStyleId;
  // UtenDropdownField 非 FormField：必填校验在 _submit 里显式判空并回显 errorMessage。
  String? _accountError;
  String? _styleError;
  late DateTime _paymentDate;

  @override
  void initState() {
    super.initState();
    _paymentDate = ChinaDateTime.today();
    _dateController = TextEditingController(text: _fmtDate(_paymentDate));
  }

  @override
  void dispose() {
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _pickPaymentDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _paymentDate,
      firstDate: DateTime(2000),
      lastDate: ChinaDateTime.today(),
      helpText: '选择付款日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _paymentDate = picked;
      _dateController.text = _fmtDate(picked);
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _accountError = _accountId == null ? '请选择付款账户' : null;
      _styleError = _expenseStyleId == null ? '请选择费用类别' : null;
    });
    if (_accountId == null || _expenseStyleId == null) return;
    Navigator.of(context).pop(
      ExpensePaymentInput(
        accountId: _accountId!,
        expenseStyleId: _expenseStyleId!,
        paymentDate: _paymentDate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final optionsAsync = ref.watch(expensePaymentOptionsProvider);
    final options = optionsAsync.valueOrNull;
    final hasOptions =
        options != null &&
        options.accounts.isNotEmpty &&
        options.styles.isNotEmpty;

    return AlertDialog(
      title: Text(AppLocalizations.of(context).expenseFlowPaymentRecord),
      content: SizedBox(
        width: 520,
        child: optionsAsync.when(
          loading: () => const SizedBox(
            height: 260,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SizedBox(
            height: 300,
            child: UtenEmpty.error(
              message: '付款主档加载失败',
              description: '请重试或联系财务维护付款账户和费用类别。',
              actionLabel: '重试',
              onAction: () => ref.invalidate(expensePaymentOptionsProvider),
            ),
          ),
          data: (loaded) {
            if (loaded.accounts.isEmpty || loaded.styles.isEmpty) {
              final missing = <String>[
                if (loaded.accounts.isEmpty) '可用付款账户',
                if (loaded.styles.isEmpty) '可用费用类别',
              ].join('和');
              return SizedBox(
                height: 300,
                child: UtenEmpty(
                  icon: Icons.account_balance_outlined,
                  message: '缺少$missing',
                  description: '请联系财务在基础资料中维护可用付款账户和费用类别，再重新加载。',
                  actionLabel: '重新加载',
                  onAction: () => ref.invalidate(expensePaymentOptionsProvider),
                ),
              );
            }

            return SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UtenDropdownField(
                      label: '付款账户',
                      required: true,
                      value: _accountId,
                      allowClear: false,
                      errorMessage: _accountError,
                      items: [
                        for (final account in loaded.accounts)
                          UtenDropdownItem(
                            value: account.id,
                            label: account.balanceCurrent == null
                                ? account.label
                                : '${account.label} · 余额 '
                                      '¥${account.balanceCurrent!.toStringAsFixed(2)}',
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _accountId = value;
                        _accountError = null;
                      }),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    UtenDropdownField(
                      label: '费用类别',
                      required: true,
                      value: _expenseStyleId,
                      allowClear: false,
                      errorMessage: _styleError,
                      items: [
                        for (final style in loaded.styles)
                          UtenDropdownItem(value: style.id, label: style.label),
                      ],
                      onChanged: (value) => setState(() {
                        _expenseStyleId = value;
                        _styleError = null;
                      }),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    TextFormField(
                      errorBuilder: utenTextFieldErrorBuilder,
                      controller: _dateController,
                      readOnly: true,
                      decoration: const UtenInputDecoration(
                        InputDecoration(
                          labelText: '付款日期 *',
                          border: OutlineInputBorder(),
                          suffixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                      ),
                      onTap: _pickPaymentDate,
                      validator: (value) =>
                          value == null || value.isEmpty ? '请选择付款日期' : null,
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      AppLocalizations.of(context).expenseFlowPaymentGuide,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: hasOptions ? _submit : null,
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: Text(AppLocalizations.of(context).expenseFlowPaymentConfirm),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.claim});
  final ExpenseClaim claim;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expenseIsSubmittedModification(claim)) ...[
            Text(
              '报销单修改',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  '${claim.applicantName} · ${claim.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenStatusBadge(
                label: claim.status.label,
                type: _badge(claim.status),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '报销总额',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '¥ ${claim.totalAmount.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '大写 ${rmbCapital(claim.totalAmount)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          if (claim.status == ExpenseClaimStatus.paid) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '已付款：${claim.paymentAccountName ?? '—'} · '
              '${claim.paymentExpenseStyleName ?? '—'} · '
              '付款日期 ${claim.paymentDate == null ? '—' : _fmtDate(claim.paymentDate!)} · '
              '出纳 ${claim.paidByName ?? '—'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ],
          if (claim.status == ExpenseClaimStatus.rejected &&
              claim.rejectReason != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '已驳回（${claim.rejectedByName ?? '—'}）：${claim.rejectReason}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

UtenStatusBadgeType _badge(ExpenseClaimStatus s) => switch (s) {
  ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
  ExpenseClaimStatus.reviewing => UtenStatusBadgeType.warning,
  ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
  ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
  ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
  ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
};

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fmt(DateTime t) =>
    '${_fmtDate(t)} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
