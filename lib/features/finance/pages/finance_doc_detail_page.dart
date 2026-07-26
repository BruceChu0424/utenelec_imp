// 钱流单据详情页（全页路由，按 docType 参数化）：主表头卡 + 只读明细子表 + 状态门控操作。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。
// 审核后端联动：核销 AR/AP（receipt/payment）/ 账户余额变动 / 写流水 / 登记对账。
// 名称解析：客户/供应商/账户/币种 用 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_status_badge.dart';

class FinanceDocDetailPage extends ConsumerStatefulWidget {
  const FinanceDocDetailPage({super.key, required this.docType, required this.id});
  final FinanceDocType docType;
  final String id;

  @override
  ConsumerState<FinanceDocDetailPage> createState() =>
      _FinanceDocDetailPageState();
}

class _FinanceDocDetailPageState extends ConsumerState<FinanceDocDetailPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  FinanceDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(financeNameServiceProvider).ensureLoaded();
      // 费用/收入单：预载 EXPENSE/INCOME 类别用于明细行项目名解析。
      if (_cfg.isAllocate) {
        await ref
            .read(financeNameServiceProvider)
            .loadStyleCategory(_cfg.type == FinanceDocType.expense
                ? 'EXPENSE'
                : 'INCOME');
      }
      final d = await ref
          .read(financeRepositoryProvider(widget.docType))
          .detail(widget.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async => _doAction('审核后将核销 AR/AP 并变动账户余额、写流水，确认审核？',
      (repo) => repo.approve(widget.id), '已审核');
  Future<void> _reverse() async => _doAction('红冲将反向冲销，确认？',
      (repo) => repo.reverse(widget.id), '已红冲');

  Future<void> _doAction(
    String confirm,
    Future<void> Function(FinanceRepository) fn,
    String ok,
  ) async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(confirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(financeRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单据'),
        content: const Text('确定删除该草稿单据吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(financeRepositoryProvider(widget.docType)).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go('/finance/${_cfg.type.pathSegment}');
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(title: '${_cfg.label}详情'),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
                  ? Center(child: Text(_error!))
                  : _detail == null
                      ? const SizedBox.shrink()
                      : ListView(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          children: [
                            _headerCard(theme, names),
                            const SizedBox(height: UtenSpacing.s12),
                            _itemsCard(theme, names),
                          ],
                        ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy
          ? null
          : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, FinanceNameService names) {
    final d = _detail!;
    final partyName = _cfg.isClient
        ? names.client(d.clientId)
        : _cfg.isSupplier
            ? names.supplier(d.supplierId)
            : null;
    final accountName = names.account(d.accountId ?? d.outAccountId);
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      if (_cfg.hasParty) _KV(_cfg.partyLabel, partyName),
      _KV(_cfg.accountLabel, accountName),
      if (_cfg.hasCurrency) _KV('币种', names.currency(d.currencyId)),
      if (d.exchangeRate != null) _KV('汇率', d.exchangeRate?.toString()),
      if (_cfg.hasBankFee && d.bankFee != null)
        _KV('银行手续费', d.bankFee?.toStringAsFixed(2)),
      if (_cfg.hasOtherFee && d.otherFee != null)
        _KV('其它手续费', d.otherFee?.toStringAsFixed(2)),
      if (_cfg.hasInvoiceNo) _KV('发票号', d.invoiceNo),
      _KV('合计(本币)', d.amountLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV('状态', null,
          badge: FinanceStatusBadge(status: d.status, closed: d.closed)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [for (final r in rows) _kvRow(theme, r)],
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(r.label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: r.badge ?? Text(r.value ?? '—')),
      ],
    );
  }

  Widget _itemsCard(ThemeData theme, FinanceNameService names) {
    final items = _detail!.items;
    if (items.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text('无明细（直接${_cfg.shortLabel}，未指定核销/分摊）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s4),
              child: Text('明细 (${items.length})',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            _itemHeader(theme),
            for (final it in items) _itemRow(theme, names, it),
          ],
        ),
      ),
    );
  }

  Widget _itemHeader(ThemeData theme) {
    final cells = <String>[];
    if (_cfg.isSettle) {
      cells.addAll(['核销单据', '本次金额', '原币额']);
    } else if (_cfg.isAllocate) {
      cells.addAll(['项目', '部门', '数量', '单价', '金额']);
    } else if (_cfg.isTransfer) {
      cells.addAll(['转入账户', '日期', '金额']);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            _icell(cells[i], _flex(i, cells.length), theme, bold: true),
        ],
      ),
    );
  }

  /// 明细列权重：第一列宽（项目名/账户名），其余等分。
  int _flex(int i, int total) => i == 0 ? 3 : 1;

  Widget _itemRow(
      ThemeData theme, FinanceNameService names, FinanceDocItem it) {
    final styleCat =
        _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
    final cells = <String>[];
    if (_cfg.isSettle) {
      cells.addAll([
        it.appliedBillNo ?? '—',
        it.amountLocal?.toStringAsFixed(2) ?? '—',
        it.amountOriginal?.toStringAsFixed(2) ?? '—',
      ]);
    } else if (_cfg.isAllocate) {
      cells.addAll([
        names.styleName(it.expenseStyleId ?? it.incomeStyleId, styleCat),
        names.client(it.departmentId).replaceAll('—', it.departmentId ?? '—'),
        it.qty?.toStringAsFixed(2) ?? '—',
        it.price?.toStringAsFixed(2) ?? '—',
        it.amountLocal?.toStringAsFixed(2) ?? '—',
      ]);
    } else if (_cfg.isTransfer) {
      cells.addAll([
        names.account(it.inAccountId),
        (it.occurDate ?? '').substring(0, 10),
        it.amountLocal?.toStringAsFixed(2) ?? '—',
      ]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            _icell(cells[i], _flex(i, cells.length), theme),
        ],
      ),
    );
  }

  Widget _icell(String? text, int flex, ThemeData theme, {bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text ?? '—',
        textAlign: flex == 1 ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 12,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
          color: bold ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final children = <Widget>[];
    if (s == kFinanceStatusDraft && _canEdit) {
      children
        ..add(UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.delete_outline,
          onPressed: _delete,
          child: const Text('删除'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.edit_outlined,
          onPressed: () => context.push(
              '/finance/${_cfg.type.pathSegment}/${widget.id}/edit'),
          child: const Text('编辑'),
        ))
        ..add(const SizedBox(width: UtenSpacing.s8))
        ..add(UtenButton(
          icon: Icons.check_circle_outline,
          onPressed: _approve,
          child: const Text('审核'),
        ));
    } else if (s == kFinanceStatusApproved && _canEdit) {
      children.add(UtenButton(
        type: UtenButtonType.danger,
        icon: Icons.undo_outlined,
        onPressed: _reverse,
        child: const Text('红冲'),
      ));
    } else {
      children.add(UtenButton(
        type: UtenButtonType.secondary,
        onPressed: () => context.go('/finance/${_cfg.type.pathSegment}'),
        child: const Text('返回列表'),
      ));
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
