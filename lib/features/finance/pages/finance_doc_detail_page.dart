// 钱流单据详情页（全页路由，按 docType 参数化）：主表头卡 + 只读明细子表 + 状态门控操作。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。
// 审核后端联动：核销 AR/AP（receipt/payment）/ 账户余额变动 / 写流水 / 登记对账。
// 名称解析：客户/供应商/账户/币种 用 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_status_badge.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';

class FinanceDocDetailPage extends ConsumerStatefulWidget {
  const FinanceDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
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

  bool _hasPermission(String? code) =>
      code != null && ref.read(currentPermissionsProvider).contains(code);

  bool get _canEdit => _hasPermission(_cfg.editPerm);
  bool get _canDelete => _hasPermission(_cfg.deletePerm);
  bool get _canApprove => _hasPermission(_cfg.approvePerm);
  bool get _canReverse => _hasPermission(_cfg.reversePerm);
  bool get _canConfirmGeneralLedger =>
      _hasPermission(Perm.financeExpenseGlConfirm);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(financeNameServiceProvider).ensureLoaded();
      // 费用/收入单及销售收款的其它费用项目：预载类别名称。
      if (_cfg.isAllocate || _cfg.type == FinanceDocType.receipt) {
        await ref
            .read(financeNameServiceProvider)
            .loadStyleCategory(
              _cfg.type == FinanceDocType.otherIncome ? 'INCOME' : 'EXPENSE',
            );
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

  Future<void> _approve() async => _doAction(
    '审核后将核销 AR/AP 并变动账户余额、写流水，确认审核？',
    (repo) => repo.approve(widget.id),
    '已审核',
    reviewerResponsibility: true,
  );
  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  /// C6 财务确认（仅费用单）：已过账 → 财务确认入账。
  Future<void> _glConfirm() async => _doAction(
    '确认该费用单的总账分录入账？',
    (repo) => repo.glConfirm(widget.id),
    '已财务确认',
    reviewerResponsibility: true,
    reviewerActionLabel: '费用单总账确认',
  );

  Future<void> _doAction(
    String confirm,
    Future<void> Function(FinanceRepository) fn,
    String ok, {
    bool reviewerResponsibility = false,
    String reviewerActionLabel = '审核',
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(
            context,
            message: confirm,
            actionLabel: reviewerActionLabel,
          )
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认'),
              content: Text(confirm),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确认'),
                ),
              ],
            ),
          );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(financeRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      bumpListRefresh(ref, _cfg.refreshKey);
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
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
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
      await ref
          .read(financeRepositoryProvider(widget.docType))
          .delete(widget.id);
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
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        // 列表行 push 进（回列表）/ hub 新建保存后 replace 进（栈空→回 hub）；
        // 用 popOrBackTo 兼顾两种入口。
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () => context.push('/finance/${_cfg.type.pathSegment}'),
            child: const Text('查看历史'),
          ),
        ],
      ),
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
                    SelectionArea(child: _headerCard(theme, names)),
                    if (_cfg.type == FinanceDocType.receipt &&
                        _detail!.receiptKind == 'CUSTOMER_PREPAYMENT' &&
                        _detail!.salesOrderId != null) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      SalesOrderMoneySummaryCard(
                        salesOrderId: _detail!.salesOrderId!,
                      ),
                    ],
                    if (!(_cfg.type == FinanceDocType.receipt &&
                        _detail!.receiptKind == 'CUSTOMER_PREPAYMENT')) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _itemsCard(theme, names),
                    ],
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  Widget _headerCard(ThemeData theme, FinanceNameService names) {
    final d = _detail!;
    final isReceipt = _cfg.type == FinanceDocType.receipt;
    final isCustomerPrepayment =
        isReceipt && d.receiptKind == 'CUSTOMER_PREPAYMENT';
    final isPayment = _cfg.type == FinanceDocType.payment;
    final partyName = _cfg.isClient
        ? names.client(d.clientId)
        : _cfg.isSupplier
        ? names.supplier(d.supplierId)
        : null;
    final accountName = names.account(d.accountId ?? d.outAccountId);
    final receiptLocal = d.items.fold<double>(
      0,
      (sum, item) => sum + (item.amountLocal ?? 0),
    );
    final writeOffLocal = d.items.fold<double>(
      0,
      (sum, item) => sum + (item.writeOffLocal ?? 0),
    );
    final appliedLocal = d.items.fold<double>(
      0,
      (sum, item) => sum + (item.appliedAmountLocal ?? 0),
    );
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (isReceipt) _KV('收款业务', financeReceiptKindLabel(d.receiptKind)),
      if (isCustomerPrepayment) _KV('绑定销售订单 UUID', d.salesOrderId),
      if (_cfg.hasParty) _KV(_cfg.partyLabel, partyName),
      _KV(_cfg.accountLabel, accountName),
      if (_cfg.hasCurrency && (!isReceipt || isCustomerPrepayment))
        _KV('币种', names.currency(d.currencyId)),
      if ((!isReceipt || isCustomerPrepayment) && d.exchangeRate != null)
        _KV('汇率', d.exchangeRate?.toString()),
      if (isCustomerPrepayment && d.amountOriginal != null)
        _KV('本次预收原币金额', d.amountOriginal?.toStringAsFixed(4)),
      if (isPayment && d.amountOriginal != null)
        _KV('付款原币金额', d.amountOriginal?.toStringAsFixed(2)),
      if (_cfg.hasBankFee && d.bankFee != null)
        _KV('手续费（人民币）', d.bankFee?.toStringAsFixed(2)),
      if (_cfg.hasOtherFee && d.otherFee != null)
        _KV('其它费用（人民币）', d.otherFee?.toStringAsFixed(2)),
      if (_cfg.hasOtherFee && d.otherFeeStyleId != null)
        _KV('其它费用项目', names.styleName(d.otherFeeStyleId, 'EXPENSE')),
      if (_cfg.hasInvoiceNo) _KV('发票号', d.invoiceNo),
      if (isCustomerPrepayment) ...[
        _KV('预收到账本币', d.amountLocal?.toStringAsFixed(4)),
        const _KV('资金来源', '已审核财务收款单；不是销售订单历史订金'),
      ] else if (isReceipt) ...[
        _KV('本次收到金额（人民币）', receiptLocal.toStringAsFixed(2)),
        _KV('冲销费用（人民币）', writeOffLocal.toStringAsFixed(2)),
        _KV('本次总收到金额（人民币）', (receiptLocal + writeOffLocal).toStringAsFixed(2)),
        _KV('冲减应收账面金额（人民币）', appliedLocal.toStringAsFixed(2)),
      ] else
        _KV(isPayment ? '付款本币合计' : '合计(本币)', d.amountLocal?.toStringAsFixed(2)),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: FinanceStatusBadge(status: d.status, closed: d.closed),
      ),
      // C6：费用单总账过账状态（0 未过账/1 待确认/2 已确认）
      if (_cfg.type == FinanceDocType.expense && d.glStatus != null)
        _KV('总账', switch (d.glStatus) {
          1 => '已过账 · 待财务确认',
          2 => '已过账 · 财务已确认',
          _ => '未过账',
        }),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(children: [for (final r in rows) _kvRow(theme, r)]),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            r.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: r.badge ?? Text(r.value ?? '—')),
      ],
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；核销/分摊/转账三类列口径不变。
  Widget _itemsCard(ThemeData theme, FinanceNameService names) {
    final items = _detail!.items;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
        child: Text(
          _cfg.type == FinanceDocType.payment
              ? '无应付核销明细（直接/预付款）'
              : '无明细（直接${_cfg.shortLabel}，未指定核销/分摊）',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final styleCat = _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
    final columns = <MasterColumnDef<FinanceDocItem>>[
      if (_cfg.type == FinanceDocType.receipt) ...[
        MasterColumnDef(
          key: 'bill',
          label: _cfg.isClient ? '应收单号' : '应付单号',
          width: 180,
          value: (it) => it.appliedBillNo,
        ),
        MasterColumnDef(
          key: 'currency',
          label: '币别',
          width: 100,
          value: (it) => names.currency(it.currencyId),
        ),
        MasterColumnDef(
          key: 'amountOriginal',
          label: _cfg.isClient ? '本次收款金额' : '本次付款金额',
          width: 130,
          type: 'money',
          value: (it) => it.amountOriginal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'exchangeRate',
          label: '汇率',
          width: 90,
          type: 'number',
          value: (it) => it.exchangeRate?.toStringAsFixed(4),
        ),
        MasterColumnDef(
          key: 'amountLocal',
          label: '换算人民币',
          width: 110,
          type: 'money',
          value: (it) => it.amountLocal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'writeOffAmount',
          label: '冲销金额（原币）',
          width: 110,
          type: 'money',
          value: (it) => it.writeOffAmount?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'writeOffLocal',
          label: '冲销人民币',
          width: 110,
          type: 'money',
          value: (it) => it.writeOffLocal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'balanceBeforeOriginal',
          label: _cfg.isClient ? '收款前未收' : '付款前未付',
          width: 110,
          type: 'money',
          value: (it) => it.balanceBeforeOriginal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'balanceAfterOriginal',
          label: _cfg.isClient ? '收款后未收' : '付款后未付',
          width: 110,
          type: 'money',
          value: (it) => it.balanceAfterOriginal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'remark',
          label: '备注',
          width: 160,
          value: (it) => it.remark,
        ),
      ] else if (_cfg.isSettle) ...[
        MasterColumnDef(
          key: 'bill',
          label: '应付单号',
          width: 180,
          value: (it) => it.appliedBillNo,
        ),
        MasterColumnDef(
          key: 'amountOriginal',
          label: '本次付款（原币）',
          width: 110,
          type: 'money',
          value: (it) => it.amountOriginal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'amountLocal',
          label: '付款本币',
          width: 110,
          type: 'money',
          value: (it) => it.amountLocal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'appliedAmountLocal',
          label: '核销账面本币',
          width: 120,
          type: 'money',
          value: (it) => it.appliedAmountLocal?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'exchangeDiff',
          label: '汇兑差额',
          width: 110,
          type: 'money',
          value: (it) => it.exchangeDiff?.toStringAsFixed(2),
        ),
      ] else if (_cfg.isAllocate) ...[
        MasterColumnDef(
          key: 'style',
          label: '项目',
          width: 160,
          value: (it) =>
              names.styleName(it.expenseStyleId ?? it.incomeStyleId, styleCat),
        ),
        MasterColumnDef(
          key: 'dept',
          label: '部门',
          width: 140,
          value: (it) => names
              .client(it.departmentId)
              .replaceAll('—', it.departmentId ?? '—'),
        ),
        MasterColumnDef(
          key: 'qty',
          label: '数量',
          width: 90,
          type: 'number',
          value: (it) => it.qty?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'price',
          label: '单价',
          width: 90,
          type: 'money',
          value: (it) => it.price?.toStringAsFixed(2),
        ),
        MasterColumnDef(
          key: 'amount',
          label: '金额',
          width: 100,
          type: 'money',
          value: (it) => it.amountLocal?.toStringAsFixed(2),
        ),
      ] else if (_cfg.isTransfer) ...[
        MasterColumnDef(
          key: 'inAccount',
          label: '转入账户',
          width: 160,
          value: (it) => names.account(it.inAccountId),
        ),
        MasterColumnDef(
          key: 'occurDate',
          label: '日期',
          width: 110,
          type: 'date',
          value: (it) => (it.occurDate ?? '').length >= 10
              ? it.occurDate!.substring(0, 10)
              : it.occurDate,
        ),
        MasterColumnDef(
          key: 'amount',
          label: '金额',
          width: 110,
          type: 'money',
          value: (it) => it.amountLocal?.toStringAsFixed(2),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '明细 (${items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        MasterDataTableView<FinanceDocItem>(
          embedded: true,
          columns: columns,
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '（无明细）',
        ),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final detail = _detail!;
    final children = <Widget>[];

    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    void addBack() {
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => context.go('/finance/${_cfg.type.pathSegment}'),
          child: const Text('返回列表'),
        ),
      );
    }

    if (detail.status == kFinanceStatusDraft) {
      if (_canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (_canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              '/finance/${_cfg.type.pathSegment}/${widget.id}/edit',
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (_canApprove) {
        addAction(
          UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: _approve,
            child: const Text('审核'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else if (detail.status == kFinanceStatusApproved) {
      if (_cfg.type == FinanceDocType.expense &&
          detail.glStatus == 1 &&
          _canConfirmGeneralLedger) {
        addAction(
          UtenButton(
            icon: Icons.fact_check_outlined,
            onPressed: _glConfirm,
            child: const Text('财务确认'),
          ),
        );
      }
      if (_canReverse) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
    }
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
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
