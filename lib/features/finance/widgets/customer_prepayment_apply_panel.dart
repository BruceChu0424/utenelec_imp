import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/customer_prepayment.dart';
import '../models/finance_decimal.dart';
import '../repositories/customer_prepayment_repository.dart';
import 'ar_ap_picker_dialog.dart';

Future<CustomerPrepaymentOffsetResult?> showCustomerPrepaymentApplyPanel(
  BuildContext context, {
  required String clientId,
}) => showUtenAdaptivePanel<CustomerPrepaymentOffsetResult>(
  context: context,
  compactHeightFactor: 0.94,
  drawerWidth: 920,
  builder: (_) => _CustomerPrepaymentApplyPanel(clientId: clientId),
);

class _CustomerPrepaymentApplyPanel extends ConsumerStatefulWidget {
  const _CustomerPrepaymentApplyPanel({required this.clientId});

  final String clientId;

  @override
  ConsumerState<_CustomerPrepaymentApplyPanel> createState() =>
      _CustomerPrepaymentApplyPanelState();
}

class _CustomerPrepaymentApplyPanelState
    extends ConsumerState<_CustomerPrepaymentApplyPanel> {
  final _reason = TextEditingController();
  CustomerPrepaymentPage? _page;
  CustomerPrepaymentItem? _source;
  List<AppliedArAp> _targets = const [];
  CustomerPrepaymentOffsetResult? _lastResult;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool _has(String permission) =>
      ref.read(currentPermissionsProvider).contains(permission);

  bool get _canApply =>
      _has(Perm.financeViewAll) &&
      _has(Perm.customerPrepaymentView) &&
      _has(Perm.customerPrepaymentApply);

  bool get _canReverse =>
      _has(Perm.financeViewAll) && _has(Perm.customerPrepaymentReverse);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(customerPrepaymentRepositoryProvider)
          .list(clientId: widget.clientId, size: 100);
      if (!mounted) return;
      setState(() => _page = page);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '客户预收加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectSource(CustomerPrepaymentItem item) {
    if (!item.hasAvailable || _busy || _lastResult != null) return;
    setState(() {
      _source = _source?.ledgerId == item.ledgerId ? null : item;
      _targets = const [];
    });
  }

  Future<void> _pickTargets() async {
    final source = _source;
    if (source == null) {
      context.appWarning('请先选择一笔可用客户预收');
      return;
    }
    final picked = await showArApPickerDialog(
      context,
      ref,
      direction: 'AR',
      partyId: widget.clientId,
      lockedCurrencyId: source.currencyId,
    );
    if (!mounted || picked == null) return;
    for (final target in picked) {
      final orderId = _targetOrderId(target);
      if (orderId == null) {
        context.appWarning(
          '${target.appliedBillNo ?? '该应收'}：缺少唯一销售订单 UUID，暂不能应用预收',
        );
        return;
      }
    }
    setState(() => _targets = picked);
  }

  String? _targetOrderId(AppliedArAp target) {
    final authoritative = target.authoritativeSalesOrderId;
    if (authoritative?.isNotEmpty == true) return authoritative;
    return target.salesOrderIds.length == 1
        ? target.salesOrderIds.single
        : null;
  }

  String? _validationError() {
    final source = _source;
    if (source == null) return '请选择一笔可用客户预收';
    if (!source.hasAvailable) return '所选客户预收已无可用余额，请刷新';
    if (_targets.isEmpty) return '请选择至少一笔同客户、同币种的正应收';
    if (_reason.text.trim().isEmpty) return '请填写应用预收原因';
    final available = financeExactDecimalUnits(source.availableOriginal);
    if (available == null || available <= BigInt.zero) {
      return '所选客户预收可用余额待财务核验';
    }
    var total = BigInt.zero;
    for (final target in _targets) {
      if (_targetOrderId(target) == null) {
        return '${target.appliedBillNo ?? '该应收'}缺少唯一销售订单 UUID';
      }
      final units = financeExactDecimalUnits(target.receiptAmountText);
      if (units == null || units <= BigInt.zero) {
        return '${target.appliedBillNo ?? '该应收'}的应用金额无效';
      }
      total += units;
    }
    if (total > available) return '应用合计不能超过所选客户预收可用余额';
    return null;
  }

  Future<void> _apply() async {
    if (_busy) return;
    if (!_canApply) {
      context.appWarning('您没有应用客户预收权限');
      return;
    }
    final validation = _validationError();
    if (validation != null) {
      context.appWarning(validation);
      return;
    }
    final source = _source!;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(customerPrepaymentRepositoryProvider)
          .apply(
            sourceLedgerId: source.ledgerId,
            targets: [
              for (final target in _targets)
                CustomerPrepaymentOffsetTarget(
                  receivableLedgerId: target.ledgerId,
                  salesOrderId: _targetOrderId(target)!,
                  amountOriginal: target.receiptAmountText,
                ),
            ],
            reason: _reason.text,
            idempotencyKey: const Uuid().v4(),
          );
      if (!mounted) return;
      setState(() => _lastResult = result);
      context.appSuccess('客户预收已应用，批次 ${result.batchId}');
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('应用客户预收失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reverse() async {
    final result = _lastResult;
    if (result == null || _busy) return;
    if (!_canReverse) {
      context.appWarning('您没有反转客户预收抵销权限');
      return;
    }
    final reason = await _askReverseReason();
    if (!mounted || reason == null) return;
    setState(() => _busy = true);
    try {
      final reversed = await ref
          .read(customerPrepaymentRepositoryProvider)
          .reverse(
            batchId: result.batchId,
            expectedVersion: result.rowVersion,
            reason: reason,
          );
      if (!mounted) return;
      context.appSuccess('客户预收抵销已反转');
      setState(() {
        _lastResult = reversed;
        _source = null;
        _targets = const [];
      });
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('反转失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askReverseReason() async {
    var reason = '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('反转本次预收抵销'),
        content: TextField(
          onChanged: (value) => reason = value,
          autofocus: true,
          maxLength: 2000,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '反转原因（必填）',
            helperText: '反转会恢复预收和目标应收余额，并保留审计记录',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = reason.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('确认反转'),
          ),
        ],
      ),
    );
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用客户预收'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: '关闭',
            onPressed: _busy ? null : () => Navigator.pop(context, _lastResult),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: SafeArea(child: _body(theme)),
      bottomNavigationBar: _loading || _error != null || _page == null
          ? null
          : _footer(theme),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _page == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final page = _page!;
    if (page.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(
            '该客户暂无可用预收。直接到账须先在财务收款单中按预收登记并审核。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      children: [
        _summary(theme, page.summary),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '1. 选择预收来源',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        for (final item in page.items) _sourceTile(theme, item),
        const SizedBox(height: UtenSpacing.s12),
        Row(
          children: [
            Expanded(
              child: Text(
                '2. 选择应收目标',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.playlist_add_check_rounded,
              onPressed: _source == null || _busy || _lastResult != null
                  ? null
                  : _pickTargets,
              child: const Text('选择应收'),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (_targets.isEmpty)
          Text(
            '尚未选择目标；仅允许同客户、同币种且带唯一销售订单 UUID 的正应收。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final target in _targets)
            ListTile(
              dense: true,
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(target.appliedBillNo ?? target.ledgerId),
              subtitle: Text(
                '${target.salesOrderNos.join('、')} · '
                '${target.currencyCode ?? '原币'} ${financeExactMoneyDisplay(target.receiptAmountText)}',
              ),
            ),
        const SizedBox(height: UtenSpacing.s12),
        TextField(
          controller: _reason,
          maxLength: 2000,
          maxLines: 3,
          enabled: !_busy && _lastResult == null,
          decoration: const InputDecoration(
            labelText: '应用原因（必填）',
            helperText: '说明订单、客户通知或其它核销依据；服务端保留完整审计记录',
          ),
        ),
        if (_lastResult case final result?) ...[
          const SizedBox(height: UtenSpacing.s12),
          _resultCard(theme, result),
        ],
      ],
    );
  }

  Widget _summary(ThemeData theme, CustomerPrepaymentSummary summary) => Card(
    color: theme.colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s8,
        children: [
          _summaryValue(theme, '累计预收', summary.receivedOriginal),
          _summaryValue(theme, '累计已抵', summary.appliedOriginal),
          _summaryValue(theme, '当前可用', summary.availableOriginal),
        ],
      ),
    ),
  );

  Widget _summaryValue(ThemeData theme, String label, String? value) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: theme.textTheme.labelMedium),
      Text(
        financeExactMoneyDisplay(value),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  Widget _sourceTile(ThemeData theme, CustomerPrepaymentItem item) {
    final selected = _source?.ledgerId == item.ledgerId;
    return Card(
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: CheckboxListTile(
        key: ValueKey('customer-prepayment-${item.ledgerId}'),
        value: selected,
        enabled: item.hasAvailable && !_busy && _lastResult == null,
        onChanged: (_) => _selectSource(item),
        title: Text(item.billNo ?? item.ledgerId),
        subtitle: Text(
          '${item.billDate ?? '—'} · ${item.currencyCode ?? item.currencyId ?? '原币'}\n'
          '到账 ${financeExactMoneyDisplay(item.receivedOriginal)} · '
          '已抵 ${financeExactMoneyDisplay(item.appliedOriginal)} · '
          '可用 ${financeExactMoneyDisplay(item.availableOriginal)}',
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }

  Widget _resultCard(ThemeData theme, CustomerPrepaymentOffsetResult result) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(UtenRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.status == 'REVERSED' ? '本次抵销已反转' : '预收已成功应用',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text('批次：${result.batchId} · 版本：${result.rowVersion}'),
            if (result.effectiveDate != null)
              Text('生效日：${result.effectiveDate}'),
          ],
        ),
      );

  Widget _footer(ThemeData theme) => SafeArea(
    child: Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : () => Navigator.pop(context, _lastResult),
            child: Text(_lastResult == null ? '取消' : '完成'),
          ),
          if (_lastResult == null)
            UtenButton(
              key: const ValueKey('customer-prepayment-apply'),
              isLoading: _busy,
              icon: Icons.account_balance_wallet_outlined,
              onPressed: _busy || !_canApply ? null : _apply,
              child: const Text('确认应用预收'),
            )
          else if (_lastResult!.status != 'REVERSED' && _canReverse)
            UtenButton(
              key: const ValueKey('customer-prepayment-reverse'),
              type: UtenButtonType.danger,
              isLoading: _busy,
              icon: Icons.undo_rounded,
              onPressed: _busy ? null : _reverse,
              child: const Text('反转本次抵销'),
            ),
        ],
      ),
    ),
  );
}
