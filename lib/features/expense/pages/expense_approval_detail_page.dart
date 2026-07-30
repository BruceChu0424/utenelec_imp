// 报销审批详情页（Phase 3）
// 文档：docs/03-页面/报销审批详情页.md · 审批流见 docs/05-架构/全局机制.md §3.3
//
// 响应式：全断点套 UtenContentContainer.narrow（maxWidth 1120）——
// 外壳只收敛到 1600，详情页需自行钳窄居中

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../models/expense_claim.dart';
import '../models/expense_payment.dart';
import '../providers/expense_providers.dart';

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

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  ExpenseClaim? get _claim =>
      ref.read(expenseDetailProvider(widget.claimId)).valueOrNull;

  bool get _canApprove {
    final c = _claim;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.expenseApprove) &&
        c != null &&
        (c.status == ExpenseClaimStatus.submitted ||
            c.status == ExpenseClaimStatus.reviewing);
  }

  bool get _canPay {
    final c = ref.read(expenseDetailProvider(widget.claimId)).valueOrNull;
    return ref.read(currentPermissionsProvider).contains(Perm.expensePay) &&
        c?.status == ExpenseClaimStatus.approved;
  }

  Future<void> _approve() async {
    setState(() => _acting = true);
    try {
      await approveExpense(ref, widget.claimId);
      if (mounted) {
        context.appSuccess('审批已通过');
        context.go('/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appError('审批失败：$error');
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
    setState(() => _acting = true);
    try {
      await rejectExpense(ref, widget.claimId, reason);
      if (mounted) {
        context.appSuccess('报销单已驳回');
        context.go('/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appError('驳回失败：$error');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _pay() async {
    final input = await showDialog<ExpensePaymentInput>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _ExpensePaymentDialog(),
    );
    if (!mounted || input == null) return;

    setState(() => _acting = true);
    try {
      await payExpense(ref, widget.claimId, input);
      if (mounted) {
        context.appSuccess('打款完成，财务记录已生成');
        context.go('/expense/approval');
      }
    } catch (error) {
      if (mounted) context.appError('打款失败：$error');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(expenseDetailProvider(widget.claimId));

    return Scaffold(
      appBar: const UtenAppBar(title: '审批详情', showBackButton: true),
      bottomNavigationBar: _canApprove
          ? UtenBottomActionBar(
              child: Row(
                children: [
                  UtenButton(
                    type: UtenButtonType.ghost,
                    isLoading: _acting,
                    icon: Icons.close_rounded,
                    onPressed: _acting ? null : _reject,
                    child: const Text('驳回'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: UtenButton(
                      isLoading: _acting,
                      isExpanded: true,
                      icon: Icons.check_rounded,
                      onPressed: _acting ? null : _approve,
                      child: const Text('通过'),
                    ),
                  ),
                ],
              ),
            )
          : _canPay
          ? UtenBottomActionBar(
              child: UtenButton(
                isLoading: _acting,
                isExpanded: true,
                icon: Icons.account_balance_wallet_outlined,
                onPressed: _acting ? null : _pay,
                child: const Text('填写付款信息并打款'),
              ),
            )
          : null,
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(expenseDetailProvider(widget.claimId)),
        ),
        data: (claim) => UtenContentContainer.narrow(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hero(claim: claim),
                const SizedBox(height: UtenSpacing.s16),
                const UtenSectionHeader(title: '申请信息'),
                const SizedBox(height: UtenSpacing.s8),
                UtenCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      UtenInfoRow(label: '申请人', value: claim.applicantName),
                      UtenInfoRow(
                        label: '标题',
                        value: claim.title,
                        isImportant: true,
                      ),
                      UtenInfoRow(
                        label: '提交时间',
                        value: _fmt(claim.submittedAt ?? claim.createdAt),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s20),
                const UtenSectionHeader(title: '报销明细'),
                const SizedBox(height: UtenSpacing.s8),
                UtenCard(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    children: [
                      for (final it in claim.items) ...[
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.receipt_outlined,
                            color: UtenColors.teal600,
                            size: 20,
                          ),
                          title: Text(
                            '${it.category.label}  ·  ${it.description ?? ''}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          trailing: Text(
                            '¥ ${it.amount.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        if (it != claim.items.last) const Divider(height: 1),
                      ],
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '共 ${claim.items.length} 项  合计 ',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            '¥ ${claim.totalAmount.toStringAsFixed(0)}',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.primary,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s20),
                const UtenSectionHeader(title: '审批轨迹'),
                const SizedBox(height: UtenSpacing.s8),
                UtenCard(child: _ApprovalTimeline(claim: claim)),
                if (_canApprove) ...[
                  const SizedBox(height: UtenSpacing.s20),
                  const UtenSectionHeader(title: '审批意见'),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenCard(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: TextField(
                      controller: _comment,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '驳回原因',
                        hintText: '驳回时必填，通过时不会提交',
                        border: OutlineInputBorder(),
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
    );
  }
}

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
  late DateTime _paymentDate;

  @override
  void initState() {
    super.initState();
    _paymentDate = ChinaDateTime.today();
    _dateController = TextEditingController(text: _fmt(_paymentDate));
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
      _dateController.text = _fmt(picked);
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
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
      title: const Text('确认报销打款'),
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
              description: '$error',
              actionLabel: '重试',
              onAction: () => ref.invalidate(expensePaymentOptionsProvider),
            ),
          ),
          data: (loaded) {
            if (loaded.accounts.isEmpty || loaded.styles.isEmpty) {
              final missing = <String>[
                if (loaded.accounts.isEmpty) '可用付款账户',
                if (loaded.styles.isEmpty) 'EXPENSE 费用类别',
              ].join('和');
              return SizedBox(
                height: 300,
                child: UtenEmpty(
                  icon: Icons.account_balance_outlined,
                  message: '缺少$missing',
                  description: '请先在基础资料中启用对应主档，打款不会使用临时或模拟数据。',
                  actionLabel: '重新加载',
                  onAction: () => ref.invalidate(expensePaymentOptionsProvider),
                ),
              );
            }

            return Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _accountId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '付款账户 *',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final account in loaded.accounts)
                        DropdownMenuItem(
                          value: account.id,
                          child: Text(
                            account.balanceCurrent == null
                                ? account.label
                                : '${account.label} · 余额 '
                                      '¥${account.balanceCurrent!.toStringAsFixed(2)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _accountId = value),
                    validator: (value) => value == null ? '请选择付款账户' : null,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  DropdownButtonFormField<String>(
                    initialValue: _expenseStyleId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '费用类别 *',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final style in loaded.styles)
                        DropdownMenuItem(
                          value: style.id,
                          child: Text(
                            style.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _expenseStyleId = value),
                    validator: (value) => value == null ? '请选择费用类别' : null,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  TextFormField(
                    controller: _dateController,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: '付款日期 *',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                    onTap: _pickPaymentDate,
                    validator: (value) =>
                        value == null || value.isEmpty ? '请选择付款日期' : null,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  Text(
                    '提交后将扣减所选账户余额，并生成资金流水和总账记录。请核对无误后操作。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: hasOptions ? _submit : null,
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: const Text('确认并打款'),
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
        gradient: const LinearGradient(
          colors: [UtenColors.teal500, UtenColors.teal600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        // 与 UtenCard 一致的圆角面板，避免"通栏色条"观感
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenStatusBadge(
            label: claim.status.label,
            type: _badge(claim.status),
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Text(
            '报销总额',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '¥ ${claim.totalAmount.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalTimeline extends StatelessWidget {
  const _ApprovalTimeline({required this.claim});
  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = <_TNode>[
      _TNode('创建报销单', claim.applicantName, _fmt(claim.createdAt), _TState.done),
      if (claim.submittedAt != null)
        _TNode(
          '提交申请',
          claim.applicantName,
          _fmt(claim.submittedAt!),
          _TState.done,
        ),
      if (claim.approvedAt != null)
        _TNode('审批通过', '', _fmt(claim.approvedAt!), _TState.done),
      if (claim.status == ExpenseClaimStatus.rejected)
        _TNode('审批驳回', '', claim.rejectReason ?? '未填写驳回原因', _TState.rejected)
      else if (claim.status == ExpenseClaimStatus.submitted ||
          claim.status == ExpenseClaimStatus.reviewing)
        const _TNode('等待审批', '', '', _TState.pending),
      if (claim.paidAt != null)
        _TNode('打款完成', '', _fmt(claim.paidAt!), _TState.done)
      else if (claim.status == ExpenseClaimStatus.approved)
        const _TNode('等待打款', '', '', _TState.pending),
    ];
    return Column(
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          _TimelineItem(node: nodes[i]),
          if (i != nodes.length - 1)
            Container(
              margin: const EdgeInsets.only(left: 7),
              width: 2,
              height: 22,
              color: theme.colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }
}

enum _TState { done, pending, rejected }

class _TNode {
  const _TNode(this.title, this.actor, this.remark, this.state);
  final String title;
  final String actor;
  final String remark;
  final _TState state;
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.node});
  final _TNode node;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (node.state) {
      _TState.done => UtenColors.teal500,
      _TState.pending => UtenColors.slate400,
      _TState.rejected => UtenColors.error,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                node.state == _TState.pending
                    ? '待处理'
                    : [
                        node.actor,
                        node.remark,
                      ].where((value) => value.isNotEmpty).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
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

String _fmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
