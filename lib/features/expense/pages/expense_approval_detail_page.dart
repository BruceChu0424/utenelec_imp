import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/models/accounting_expense_purpose.dart';
import '../../../shared/formatters/money_display.dart';
// 报销审批详情页（审批人/财务视角）
// 文档：docs/03-页面/报销审批详情页.md · 审批流见 docs/05-架构/全局机制.md §3.3
//
// 2026-09-19 V608 全链路改版：对齐财审页（finance_procurement_approval_review_page）
// 范式——卡片序 + 内嵌明细表（两位小数，修复原 toStringAsFixed(0) 抹零）+
// 发票登记只读核对 + 发票影像附件（审批人核对票据的核心场景，V608 补齐）+
// 事件表真审批轨迹 + 打款结果回显；右下 返回/驳回 danger/通过 success、
// APPROVED 态「登记付款」；AppBar 打印报销单。
// 宽度口径：默认 1600 容器。

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/nav_helpers.dart';
import '../models/expense_invoice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../finance/widgets/finance_native_original_section.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/sensitive_content_boundary.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../../shared/widgets/task_claim_badge.dart';
import '../../../shared/widgets/task_claim_handle.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../widgets/expense_item_columns.dart';
import '../models/expense_payment.dart';
import '../providers/expense_providers.dart';
import '../providers/expense_action_eligibility.dart';
import '../repositories/expense_repository.dart';
import '../widgets/expense_claim_print.dart';
import '../widgets/expense_claim_timeline.dart';
import '../widgets/expense_financial_application_link.dart';
import '../widgets/expense_approval_progress.dart';
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
  bool _networkBusy = false;
  int _operationGeneration = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual(expenseActionEligibilityProvider, (previous, next) {
      if (previous == next) return;
      if (previous?.owner != next.owner) _comment.clear();
      _retireAction();
    });
    ref.listenManual(readScopeRevisionProvider, (previous, next) {
      if (previous != next) _retireAction();
    });
  }

  @override
  void didUpdateWidget(covariant ExpenseApprovalDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.claimId != widget.claimId) {
      ++_operationGeneration;
      _acting = false;
      _networkBusy = false;
      _comment.clear();
    }
  }

  void _retireAction() {
    if (!mounted) return;
    ++_operationGeneration;
    if (_acting || _networkBusy) {
      setState(() {
        _acting = false;
        _networkBusy = false;
      });
    }
  }

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
      ref.read(expenseDetailProvider(widget.claimId)).value;

  bool get _canApprove {
    return ref.read(expenseActionEligibilityProvider).canReviewClaim(_claim);
  }

  bool get _canInspect {
    return ref.read(expenseActionEligibilityProvider).canInspectClaim(_claim);
  }

  bool get _canPay {
    return ref.read(expenseActionEligibilityProvider).canPayClaim(_claim);
  }

  Future<void> _approve() async {
    final claim = _claim;
    final id = widget.claimId;
    if (_acting || claim == null || !_canInspect) return;
    if (ref
            .read(expenseActionEligibilityProvider)
            .requiresVerifiedInvoices(claim) &&
        claim.invoices.any(
          (invoice) => invoice.checkState != ExpenseInvoiceCheckState.verified,
        )) {
      context.appWarning(
        AppLocalizations.of(context).expenseFlowVerifyBeforeApprove,
      );
      return;
    }
    await _runAction(
      (current) async {
        bool decisionCurrent() {
          if (!current() || !_canInspect) return false;
          final detail = ref.read(expenseDetailProvider(id));
          final latest = detail.value;
          return !detail.isLoading &&
              !detail.hasError &&
              latest?.id == claim.id &&
              latest?.version == claim.version;
        }

        if (!decisionCurrent()) return false;
        setState(() => _networkBusy = false);
        final confirmed = await UtenBusyOverlay.yieldWhile(() async {
          if (!decisionCurrent()) return false;
          return showUtenReviewerConfirmDialog(
            context,
            title: '确认审批',
            message: '确认通过当前报销审批节点？',
            confirmLabel: '确认通过',
            actionLabel: '报销审批',
          );
        });
        if (!confirmed || !decisionCurrent()) return false;
        setState(() => _networkBusy = true);
        await approveExpense(
          ref,
          id,
          expectedVersion: claim.version,
          stillCurrent: decisionCurrent,
        );
        return true;
      },
      () {
        context.appSuccess('审批已通过');
        backTo(context, defaultPath: '/expense/approval');
      },
    );
  }

  Future<void> _reject() async {
    final claim = _claim;
    final id = widget.claimId;
    if (_acting || claim == null || !_canApprove) return;
    final reason = _comment.text.trim();
    if (reason.isEmpty) {
      context.appError('请填写驳回原因');
      return;
    }
    await _runAction(
      (current) async {
        if (!current() || !_canApprove) return false;
        await rejectExpense(
          ref,
          id,
          reason,
          expectedVersion: claim.version,
          stillCurrent: current,
        );
        return true;
      },
      () {
        context.appSuccess('报销单已驳回，等待申请人修订后重新提交');
        backTo(context, defaultPath: '/expense/approval');
      },
    );
  }

  Future<void> _pay() async {
    final paymentClaim = _claim;
    final id = widget.claimId;
    if (_acting || paymentClaim == null || !_canPay) return;
    if (paymentClaim.paymentProofs.isEmpty) {
      context.appWarning(
        AppLocalizations.of(context).expenseFlowPaymentProofRequired,
      );
      return;
    }
    await _runAction(
      (current) async {
        final boundary = ref.read(sensitiveReadBoundaryProvider);
        setState(() => _networkBusy = false);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !current()) return false;
        final input = await showDialog<ExpensePaymentInput>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SensitiveContentBoundary(
            boundary: boundary,
            isCurrent: current,
            invalidatedBuilder: (dialogContext) => UtenAlertDialog(
              title: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('授权已变化'),
                  SizedBox(width: UtenSpacing.s8),
                  UtenFieldHintIcon(info: '请关闭后重新打开付款登记', dense: true),
                ],
              ),
              showCloseButton: true,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
            child: const _ExpensePaymentDialog(),
          ),
        );
        if (input == null || !current() || !_canPay) return false;
        setState(() => _networkBusy = true);
        await payExpense(
          ref,
          id,
          input,
          expectedVersion: paymentClaim.version,
          stillCurrent: current,
        );
        return true;
      },
      () {
        context.appSuccess(AppLocalizations.of(context).expenseFlowPaymentDone);
        backTo(context, defaultPath: '/expense/approval');
      },
    );
  }

  Future<void> _runAction(
    Future<bool> Function(bool Function()) write,
    VoidCallback succeeded,
  ) async {
    final eligibility = ref.read(expenseActionEligibilityProvider);
    final repository = ref.read(expenseRepositoryProvider);
    final id = widget.claimId;
    final operation = ++_operationGeneration;
    bool current() =>
        mounted &&
        operation == _operationGeneration &&
        widget.claimId == id &&
        ref.read(expenseActionEligibilityProvider) == eligibility &&
        identical(ref.read(expenseRepositoryProvider), repository);
    setState(() {
      _acting = true;
      _networkBusy = true;
    });
    try {
      final completed = await runSensitiveWrite<bool>(
        ref,
        isCurrent: current,
        write: () => write(current),
      );
      if (completed && current()) {
        setState(() {
          _acting = false;
          _networkBusy = false;
        });
        succeeded();
      }
    } catch (error) {
      if (mounted && current()) {
        setState(() {
          _acting = false;
          _networkBusy = false;
        });
        context.appApiError(error);
      }
    } finally {
      if (mounted && operation == _operationGeneration) {
        setState(() {
          _acting = false;
          _networkBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(expenseActionEligibilityProvider);
    final detail = ref.watch(expenseDetailProvider(widget.claimId));
    final theme = Theme.of(context);

    return Stack(
      children: [
        Scaffold(
          appBar: UtenAppBar(
            title: '报销审批详情',
            info: '部门负责人审核后，依次交财务初核、财务复核和总经办批准，最终批准后登记付款。凭证查看下载与节点审批分别授权。',
            showBackButton: true,
            actions: [
              detail.maybeWhen(
                data: (claim) =>
                    ExpenseFinancialApplicationLinkButton(claim: claim),
                orElse: () => const SizedBox.shrink(),
              ),
              detail.maybeWhen(
                data: (claim) => UtenButton(
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  icon: Icons.print_outlined,
                  onPressed: () => showExpenseClaimPrintPreview(context, claim),
                  child: const Text('打印报销单'),
                ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
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
                          isLoading: _networkBusy,
                          icon: Icons.close_rounded,
                          onPressed: (_acting || blocked) ? null : _reject,
                          child: const Text('驳回'),
                        ),
                        if (_canInspect)
                          UtenButton(
                            type: UtenButtonType.success,
                            size: UtenButtonSize.large,
                            isLoading: _networkBusy,
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
                      isLoading: _networkBusy,
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
              error: e,
              message: '加载失败，请重试',
              onAction: () =>
                  ref.invalidate(expenseDetailProvider(widget.claimId)),
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
                      ExpenseApprovalProgress(claim: claim),
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
                      ExpenseSubmissionChangeSummary(claim: claim),
                      _itemsSection(theme, claim),
                      const SizedBox(height: UtenSpacing.s20),
                      _sectionTitle(theme, '发票登记'),
                      const SizedBox(height: UtenSpacing.s8),
                      ExpenseInvoiceSection(
                        claim: claim,
                        editable: false,
                        canVerify: ref
                            .watch(expenseActionEligibilityProvider)
                            .canVerifyInvoice(claim),
                        stickyHeaderPinned: _invoicePinned,
                      ),
                      const SizedBox(height: UtenSpacing.s20),
                      if (claim.applicationKind != null) ...[
                        FinanceNativeOriginalSection(
                          ownerType: 'EXPENSE_CLAIM',
                          ownerId: claim.id,
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
                      if (_canApprove) ...[
                        const SizedBox(height: UtenSpacing.s20),
                        TaskClaimHandle(
                          targetType: 'EXPENSE_APPROVE',
                          targetKey: widget.claimId,
                          builder: (heldByMe, taskClaim) => Row(
                            children: [
                              Text(
                                '审批意见',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Flexible(
                                child: UtenReviewerResponsibilityNotice(
                                  actionLabel: '报销审批',
                                  inline: true,
                                  description: !_canInspect
                                      ? AppLocalizations.of(
                                          context,
                                        ).expenseFlowReadEvidenceRequired
                                      : '通过或驳回将记录当前审核员与节点。请核对明细和原件；财务节点须登记凭证查验，驳回须写明修改原因。',
                                ),
                              ),
                              if (!heldByMe && taskClaim != null)
                                TaskClaimBadge(claim: taskClaim),
                            ],
                          ),
                        ),
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
        ),
        if (_networkBusy)
          const UtenBusyOverlay(title: '正在处理报销', showDoNotLeaveHint: false),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
  );

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
            tableKey:
                'features.expense.pages.expense_approval_detail_page.ExpenseApprovalDetailPageState._itemsSection.1',
            key: const Key('expense-approval-items'),
            columns: _itemColumns,
            items: claim.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            embedded: true,
            stickyHeaderPinned: _itemsPinned,
            summaryBar: UtenTotalsSummaryBar(
              rowCount: claim.items.length,
              compact: true,
              entries: [
                UtenTotalEntry(
                  '合计',
                  '${financeExactMoneyDisplay(claim.totalAmountText)} 元',
                ),
              ],
            ),
          ),
      ],
    );
  }
}

final _itemColumns = expenseItemColumns;

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
  AccountingExpensePurpose _postingPurpose =
      AccountingExpensePurpose.ordinaryExpense;
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
    final picked = await showUtenDatePicker(
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
        postingPurpose: _postingPurpose,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final optionsProvider =
        _postingPurpose == AccountingExpensePurpose.ordinaryExpense
        ? expensePaymentOptionsProvider
        : expensePaymentOptionsForPurposeProvider(_postingPurpose);
    final optionsAsync = ref.watch(optionsProvider);
    final options = optionsAsync.value;
    final hasOptions =
        options != null &&
        options.accounts.isNotEmpty &&
        options.styles.isNotEmpty;

    return Stack(
      children: [
        UtenAlertDialog(
          scrollable: false,
          title: Row(
            children: [
              Expanded(
                child: Text(
                  AppLocalizations.of(context).expenseFlowPaymentRecord,
                ),
              ),
              UtenFieldHintIcon(
                info: AppLocalizations.of(context).expenseFlowPaymentGuide,
              ),
            ],
          ),
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
                  error: error,
                  message: '付款账户和费用类别没有加载出来',
                  description: '请重试或联系财务维护付款账户和费用类别。',
                  actionLabel: '重试',
                  onAction: () => ref.invalidate(optionsProvider),
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
                      onAction: () => ref.invalidate(optionsProvider),
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
                          label: '支付用途',
                          value: _postingPurpose.apiValue,
                          items: [
                            for (final purpose
                                in AccountingExpensePurpose.values)
                              UtenDropdownItem(
                                value: purpose.apiValue,
                                label: purpose.label,
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _postingPurpose =
                                  AccountingExpensePurpose.fromApi(value);
                              _expenseStyleId = null;
                              _styleError = null;
                            });
                          },
                        ),
                        const SizedBox(height: UtenSpacing.s16),
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
                                          '${financeMoneyWithUnitSuffix(account.balanceCurrentText ?? account.balanceCurrent?.toString(), currencyName: account.currencyName, currencyCode: account.currencyCode)}',
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _accountId = value;
                            _accountError = null;
                          }),
                        ),
                        const SizedBox(height: UtenSpacing.s16),
                        UtenDropdownField(
                          label:
                              _postingPurpose ==
                                  AccountingExpensePurpose.manufacturingCost
                              ? '制造费用科目'
                              : '费用类别',
                          required: true,
                          value: _expenseStyleId,
                          allowClear: false,
                          errorMessage: _styleError,
                          items: [
                            for (final style in loaded.styles)
                              UtenDropdownItem(
                                value: style.id,
                                label: style.label,
                              ),
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
              label: Text(
                AppLocalizations.of(context).expenseFlowPaymentConfirm,
              ),
            ),
          ],
        ),
        if (optionsAsync.isLoading)
          const UtenBusyOverlay(title: '正在读取付款选项', showDoNotLeaveHint: false),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.claim});
  final ExpenseClaim claim;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenDetailSummaryCard(
      key: ValueKey('expense-approval-summary-${claim.id}'),
      heading: Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (expenseIsSubmittedModification(claim)) const Text('报销单修改'),
          Text('${claim.claimNo} · ${claim.title}'),
        ],
      ),
      status: UtenStatusBadge(
        label: claim.progressLabel,
        type: _badge(claim.status),
      ),
      primary: [
        UtenSummaryField(
          label: '报销总额',
          value: '${financeExactMoneyDisplay(claim.totalAmountText)} 元',
          emphasis: true,
          danger: true,
        ),
      ],
      facts: [
        UtenSummaryField(label: '申请人', value: claim.applicantName),
        UtenSummaryField(label: '部门', value: claim.departmentName),
        UtenSummaryField(
          label: '提交时间',
          value: _fmt(claim.submittedAt ?? claim.createdAt),
        ),
      ],
      details: [
        if (claim.remark != null && claim.remark!.trim().isNotEmpty)
          UtenSummaryField(label: '备注', value: claim.remark),
      ],
      notices: [
        if (claim.status == ExpenseClaimStatus.paid)
          Text(
            '已付款：${claim.paymentAccountName ?? '—'} · '
            '${claim.paymentExpenseStyleName ?? '—'} · '
            '付款日期 ${claim.paymentDate == null ? '—' : _fmtDate(claim.paymentDate!)} · '
            '出纳 ${claim.paidByName ?? '—'}',
            style: theme.textTheme.bodySmall,
          ),
        if (claim.status == ExpenseClaimStatus.rejected &&
            claim.rejectReason != null)
          Text(
            '已驳回（${claim.rejectedByName ?? '—'}）：${claim.rejectReason}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

// 与报销列表状态列同口径（ADR-169 档位锚定）：草稿=灰 / 待审批·审批中=蓝
// （已提交流转）/ 已通过待打款=琥珀（等待登记付款）/ 驳回=红 / 已付款=绿。
UtenStatusBadgeType _badge(ExpenseClaimStatus s) => switch (s) {
  ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
  ExpenseClaimStatus.reviewing => UtenStatusBadgeType.info,
  ExpenseClaimStatus.approved => UtenStatusBadgeType.warning,
  ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
  ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
  ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
};

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fmt(DateTime t) => ChinaDateTime.formatDateTime(t);
