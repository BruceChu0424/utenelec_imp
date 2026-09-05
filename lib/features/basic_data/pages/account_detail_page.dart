import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/currency_display.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';
import '../models/currency_node.dart';
import '../models/payment_style_node.dart';
import '../repositories/account_repository.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/account_balance_reconciliation_dialog.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class AccountDetailPage extends ConsumerStatefulWidget {
  const AccountDetailPage({
    super.key,
    required this.accountId,
    this.startEditing = false,
  });

  final String accountId;
  final bool startEditing;

  @override
  ConsumerState<AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends ConsumerState<AccountDetailPage> {
  AccountDetail? _detail;
  Map<String, CurrencyListItem> _currencies = const {};
  List<MasterSelectOption> _styleOptions = const [];
  String? _styleLoadError;
  Future<bool>? _referenceOptionsFuture;
  bool _loading = true;
  bool _detailBusy = false;
  String? _error;

  AccountStatementPage? _statement;
  final _flowRequests = LatestRequestGuard();
  bool _flowLoading = false;
  String? _flowError;
  int _flowPage = 1;
  String _flowKeyword = '';
  int _searchEpoch = 0;
  late DateTime _from;
  late DateTime _to;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  bool get _isAdmin => ref.read(isSuperAdminProvider);
  bool get _canEdit => _isAdmin || _permissions.contains(Perm.accountEdit);
  bool get _canDelete => _isAdmin || _permissions.contains(Perm.accountDelete);
  bool get _canStatus => _isAdmin || _permissions.contains(Perm.accountStatus);
  bool get _canViewBalance =>
      _isAdmin || _permissions.contains(Perm.accountBalanceView);
  bool get _canAdjustBalance =>
      _canViewBalance &&
      (_isAdmin || _permissions.contains(Perm.accountBalanceAdjust));
  bool get _canViewFlow =>
      _canViewBalance &&
      (_isAdmin || _permissions.contains(Perm.accountFlowView));
  bool get _canManageWarning =>
      _canViewBalance &&
      (_isAdmin || _permissions.contains(Perm.accountWarningManage));

  @override
  void initState() {
    super.initState();
    _resetDates();
    _load(initial: true);
  }

  void _resetDates() {
    _to = ChinaDateTime.today();
    _from = DateTime(_to.year, _to.month);
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<void> _load({bool initial = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(accountRepositoryProvider)
          .detail(widget.accountId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      if (_canViewFlow) await _loadFlow(1);
      if (initial && widget.startEditing && mounted && _canEdit) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showEdit();
        });
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载账户详情失败';
        _loading = false;
      });
    }
  }

  Future<bool> _ensureReferenceOptions() {
    if (_currencies.isNotEmpty &&
        _styleOptions.isNotEmpty &&
        _styleLoadError == null) {
      return Future<bool>.value(true);
    }
    final pending = _referenceOptionsFuture;
    if (pending != null) return pending;
    context.appInfo('正在加载币种和会计科目，请稍候…');
    final future = _loadReferenceOptions();
    _referenceOptionsFuture = future;
    return future;
  }

  Future<bool> _loadReferenceOptions() async {
    try {
      final results = await Future.wait<Object>([
        ref.read(currencyRepositoryProvider).dict(),
        ref
            .read(paymentStyleRepositoryProvider)
            .tree(category: PaymentStyleCategory.account.value),
      ]);
      final currencies = results[0] as List<CurrencyListItem>;
      final roots = results[1] as List<PaymentStyleNode>;
      final leaves = activeAccountStyleLeaves(roots);
      if (!mounted) return false;
      setState(() {
        _currencies = {for (final item in currencies) item.id: item};
        _styleOptions = [
          for (final style in leaves)
            MasterSelectOption(
              value: style.id,
              label: style.code.isEmpty
                  ? style.name
                  : '${style.code} · ${style.name}',
            ),
        ];
        _styleLoadError = currencies.isEmpty
            ? '没有可用的币种资料'
            : leaves.isEmpty
            ? '没有可用的账户类末级会计科目'
            : null;
      });
      return _styleLoadError == null;
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _styleLoadError = '币种或会计科目加载失败，请重试';
      });
      return false;
    } finally {
      _referenceOptionsFuture = null;
    }
  }

  Future<void> _loadFlow(int page) async {
    if (!_canViewFlow) return;
    if (_from.isAfter(_to)) {
      context.appError('起始日期不能晚于结束日期');
      return;
    }
    final generation = _flowRequests.begin();
    setState(() {
      _flowLoading = true;
      _flowError = null;
      _flowPage = page;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .statement(
            accountId: widget.accountId,
            dateFrom: _date(_from),
            dateTo: _date(_to),
            keyword: _flowKeyword,
            page: page,
          );
      if (!mounted || !_flowRequests.isCurrent(generation)) return;
      setState(() {
        _statement = result;
        _flowLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || !_flowRequests.isCurrent(generation)) return;
      setState(() {
        _flowError = error.message;
        _flowLoading = false;
      });
    } catch (_) {
      if (!mounted || !_flowRequests.isCurrent(generation)) return;
      setState(() {
        _flowError = '加载账户流水失败';
        _flowLoading = false;
      });
    }
  }

  String _currencyLabel(String? id, {String? name, String? code}) {
    if (id == null) return '未设置币种';
    final currency = _currencies[id];
    return financeCurrencyDisplayLabel(
          name: name ?? currency?.name,
          code: code ?? currency?.code,
        ) ??
        '未设置币种';
  }

  String _money(String? value) => financeExactMoneyDisplay(value);

  List<MasterFieldDef> get _editFields => [
    const MasterFieldDef(
      key: 'name',
      label: '账户名称',
      required: true,
      group: '基础',
    ),
    const MasterFieldDef(
      key: 'code',
      label: '账户编号',
      group: '基础',
      hint: '留空自动生成；已有编号可修改，旧编号不会被复用',
    ),
    const MasterFieldDef(key: 'bankAccountNo', label: '银行账号', group: '基础'),
    MasterFieldDef(
      key: 'accountType',
      label: '账户类型',
      required: true,
      group: '基础',
      type: MasterFieldType.select,
      options: [
        for (final type in AccountType.values)
          MasterSelectOption(value: type.value, label: type.label),
      ],
    ),
    MasterFieldDef(
      key: 'currencyId',
      label: '币种',
      group: '基础',
      type: MasterFieldType.select,
      options: [
        for (final currency in _currencies.values)
          MasterSelectOption(
            value: currency.id,
            label: _currencyLabel(currency.id),
          ),
      ],
    ),
    MasterFieldDef(
      key: 'styleId',
      label: '会计科目',
      required: true,
      group: '基础',
      type: MasterFieldType.select,
      options: _styleOptions,
      hint: '必须选择使用中的 ACCOUNT 末级科目（UUID 关联）',
    ),
    const MasterFieldDef(
      key: 'status',
      label: '状态',
      required: true,
      group: '基础',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
    ),
  ];

  Future<void> _showEdit() async {
    if (_detail == null || !_canEdit) return;
    final referencesReady = await _ensureReferenceOptions();
    if (!mounted) return;
    if (!referencesReady) {
      context.appError(_styleLoadError ?? '币种或会计科目加载失败，请重试');
      return;
    }
    final detail = _detail!;
    final styleAvailable =
        detail.styleId != null &&
        _styleOptions.any((option) => option.value == detail.styleId);
    if (!styleAvailable) {
      context.appError('该账户缺少可用的会计科目 UUID，请重新选择后再保存');
    }
    await showMasterEditDialog(
      context: context,
      title: '编辑账户',
      fields: _editFields,
      initialValues: {
        'name': detail.name ?? '',
        'code': detail.code ?? '',
        'bankAccountNo': detail.bankAccountNo ?? '',
        'accountType': detail.accountType ?? '',
        'currencyId': detail.currencyId ?? '',
        'styleId': styleAvailable ? detail.styleId! : '',
        'status': detail.status ?? '使用',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) async {
        final updated = await context.guardAction<AccountDetail>(
          () => ref.read(accountRepositoryProvider).update(detail.id, body),
          success: '账户已更新',
          errorFallback: '更新失败，请稍后重试',
        );
        if (updated == null || !mounted) return false;
        setState(() => _detail = updated);
        return true;
      },
    );
  }

  Future<void> _showWarningEditor() async {
    if (!_canManageWarning) return;
    final controller = TextEditingController(
      text: _detail?.balanceFloorText ?? '',
    );
    String? errorMessage;
    final value = await showDialog<_WarningValue>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('设置余额警戒线'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: InputDecoration(
                label: fieldLabel(
                  '低余额警戒线',
                  Theme.of(dialogContext),
                  info: '余额低于该值时标记预警；留空表示清除警戒线。',
                ),
                error: utenFieldError(errorMessage),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                final units = financeExactDecimalUnits(raw);
                if (raw.isNotEmpty &&
                    (!RegExp(r'^-?\d{1,14}(\.\d{1,4})?$').hasMatch(raw) ||
                        units == null)) {
                  setDialogState(() => errorMessage = '最多 14 位整数、4 位小数，可为负数');
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _WarningValue(
                    raw.isEmpty ? null : financeExactDecimalFromUnits(units!),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    final ok = await context.guardRun(
      () => ref
          .read(accountRepositoryProvider)
          .updateWarning(widget.accountId, balanceFloor: value.value),
      success: value.value == null ? '已清除余额警戒线' : '余额警戒线已更新',
      errorFallback: '警戒线更新失败，请稍后重试',
    );
    if (ok && mounted) await _load();
  }

  Future<void> _toggleStatus() async {
    final detail = _detail;
    if (detail == null || !_canStatus) return;
    final next = detail.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: AccountEndpoints.one(detail.id), status: next),
      success: next == '禁用' ? '账户已停用' : '账户已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _load();
  }

  Future<void> _adjustBalance() async {
    if (!_canAdjustBalance) return;
    final result = await showAccountBalanceReconciliationDialog(
      context,
      initialAccountId: widget.accountId,
    );
    if (result == null || !mounted) return;
    context.appSuccess(
      '余额核对批次 ${result.batchNo ?? result.id} 已提交，'
      '更新 ${result.changedCount}/${result.itemCount} 个账户',
    );
    await _load();
  }

  Future<void> _delete() async {
    final detail = _detail;
    if (detail == null || !_canDelete) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除账户'),
        content: Text(
          '确定删除「${detail.name?.isNotEmpty == true ? detail.name! : (detail.code ?? '该账户')}」吗？'
          '已有资金事实的账户会被服务端拒绝删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deleted = await context.guardRun(
      () => ref.read(accountRepositoryProvider).delete(detail.id),
      success: '账户已删除',
      errorFallback: '删除失败，请稍后重试',
    );
    if (deleted && mounted) {
      popOrBackTo(context, defaultPath: RouteName.basicinfoAccount);
    }
  }

  Future<void> _refresh() async {
    if (_detailBusy) return;
    _detailBusy = true;
    await _load();
    _detailBusy = false;
  }

  List<MasterDetailStat> _cardStats(AccountDetail detail) {
    final stats = <MasterDetailStat>[
      MasterDetailStat('银行账号', detail.bankAccountNo),
      MasterDetailStat('状态', detail.status),
    ];
    if (_canViewBalance) {
      stats.addAll([
        MasterDetailStat('期初余额', _money(detail.initBalanceText)),
        MasterDetailStat('余额调整', _money(detail.adjustmentsTotalText)),
        MasterDetailStat('累计收款', _money(detail.receiptsTotalText)),
        MasterDetailStat('累计付款', _money(detail.paymentsTotalText)),
        MasterDetailStat('当前余额', _money(detail.balanceCurrentText)),
        MasterDetailStat('流水重建余额', _money(detail.flowBalanceText)),
        MasterDetailStat(
          '快照/流水差异',
          detail.flowIntegrity == null
              ? '未核验'
              : detail.flowIntegrity!
              ? '一致(0.00)'
              : _money(detail.balanceDifferenceText),
        ),
        MasterDetailStat('有效流水', detail.activeFlowCount?.toString() ?? '未核验'),
        MasterDetailStat('余额警戒线', _money(detail.balanceFloorText)),
      ]);
    }
    return stats;
  }

  List<MasterColumnDef<AccountStatementRow>> get _flowColumns => [
    MasterColumnDef(
      key: 'billDate',
      label: '日期',
      width: 150,
      type: 'date',
      value: (row) => row.billDate?.replaceFirst('T', ' ').split('.').first,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '单号',
      width: 150,
      value: (row) => row.billNo,
    ),
    MasterColumnDef(
      key: 'sourceDocType',
      label: '业务类型',
      width: 120,
      value: (row) => _flowSourceLabel(row.sourceDocType),
    ),
    MasterColumnDef(
      key: 'entryKind',
      label: '流水类型',
      width: 110,
      value: (row) => switch (row.entryKind) {
        'POSTING' => '原始入账',
        'REVERSAL' => '反向流水',
        'ADJUSTMENT' => '余额调整',
        _ => row.entryKind ?? '—',
      },
    ),
    MasterColumnDef(
      key: 'summary',
      label: '摘要',
      width: 190,
      value: (row) => row.summary,
    ),
    MasterColumnDef(
      key: 'counterpartName',
      label: '对方单位',
      width: 170,
      value: (row) => row.counterpartName,
    ),
    MasterColumnDef(
      key: 'checkNo',
      label: '支票号',
      width: 130,
      value: (row) => row.checkNo,
    ),
    MasterColumnDef(
      key: 'inAmount',
      label: '收入',
      width: 130,
      type: 'money',
      value: (row) =>
          row.inAmountText == null ? null : _money(row.inAmountText),
    ),
    MasterColumnDef(
      key: 'outAmount',
      label: '支出',
      width: 130,
      type: 'money',
      value: (row) =>
          row.outAmountText == null ? null : _money(row.outAmountText),
    ),
    MasterColumnDef(
      key: 'balance',
      label: '余额',
      width: 140,
      type: 'money',
      value: (row) => row.balanceText == null ? null : _money(row.balanceText),
    ),
    MasterColumnDef(
      key: 'source',
      label: '来源',
      width: 160,
      value: (row) => row.source,
    ),
  ];

  void _showFlowDetail(AccountStatementRow row) {
    showMasterDetailSheet(
      context: context,
      title: row.billNo?.isNotEmpty == true ? row.billNo! : '流水详情',
      rows: [
        MasterDetailRow('日期', row.billDate?.replaceFirst('T', ' ')),
        MasterDetailRow('单号', row.billNo),
        MasterDetailRow('业务类型', _flowSourceLabel(row.sourceDocType)),
        MasterDetailRow('摘要', row.summary),
        MasterDetailRow('对方单位', row.counterpartName),
        MasterDetailRow('支票号', row.checkNo),
        MasterDetailRow('收入', _money(row.inAmountText)),
        MasterDetailRow('支出', _money(row.outAmountText)),
        MasterDetailRow('滚动余额', _money(row.balanceText)),
        MasterDetailRow('来源', row.source),
        MasterDetailRow('核销日期', row.settledDate?.replaceFirst('T', ' ')),
      ],
    );
  }

  String _flowSourceLabel(String? value) => switch (value) {
    'RECEIPT' => '收款',
    'PAYMENT' => '付款',
    'EXPENSE' => '费用',
    'INCOME' => '其他收入',
    'BANK_TRANSFER' => '银行转账',
    'BALANCE_ADJUSTMENT' => '余额校准',
    null || '' => '—',
    _ => value,
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final detail = _detail;
    final title = detail?.name?.isNotEmpty == true
        ? detail!.name!
        : (detail?.code ?? '账户详情');
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.basicinfoAccount),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(child: _buildContent(detail)),
      ),
    );
  }

  Widget _buildContent(AccountDetail? detail) {
    if (_loading && detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && detail == null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _refresh,
      );
    }
    if (detail == null) {
      return UtenEmpty.error(message: '账户不存在或已被删除');
    }
    final subtitle =
        '编号 ${detail.code ?? '—'} · '
        '${AccountType.labelOf(detail.accountType)} · '
        '${_currencyLabel(detail.currencyId, name: detail.currencyName, code: detail.currencyCode)}';
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s4,
            UtenSpacing.s8,
            UtenSpacing.s4,
            UtenSpacing.s12,
          ),
          child: MasterDetailCard(
            title: detail.name?.isNotEmpty == true
                ? detail.name!
                : (detail.code ?? '账户详情'),
            subtitle: subtitle,
            stats: _cardStats(detail),
            icon: Icons.account_balance_outlined,
            canEdit: _canEdit,
            canAddChild: false,
            canDelete: _canDelete,
            onAddChild: () {},
            onEdit: _showEdit,
            onDelete: _delete,
            deleteLabel: '删除账户',
            extraActions: [
              if (_canStatus)
                MasterDetailCardAction(
                  icon: detail.status == '使用'
                      ? Icons.pause_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                  label: detail.status == '使用' ? '停用账户' : '启用账户',
                  type: detail.status == '使用'
                      ? UtenButtonType.danger
                      : UtenButtonType.tonal,
                  onPressed: _toggleStatus,
                ),
              if (_canAdjustBalance)
                MasterDetailCardAction(
                  icon: Icons.fact_check_outlined,
                  label: '余额校准',
                  onPressed: _adjustBalance,
                ),
              if (_canManageWarning)
                MasterDetailCardAction(
                  icon: Icons.warning_amber_rounded,
                  label: '设置警戒线',
                  onPressed: _showWarningEditor,
                ),
            ],
          ),
        ),
        body: _buildFlowBody(),
      ),
    );
  }

  Widget _buildFlowBody() {
    if (!_canViewBalance) {
      return _lockedFlow(
        icon: Icons.lock_outline_rounded,
        message: '你可以查看账户基本资料，但未获授权查看余额与流水金额。',
      );
    }
    if (!_canViewFlow) {
      return _lockedFlow(
        icon: Icons.lock_clock_outlined,
        message: '当前账号没有账户流水查看权限。请由授权管理员在“账户”权限页单独授予。',
      );
    }
    return Column(
      children: [
        _flowFilters(),
        Expanded(
          child: MasterDataTableView<AccountStatementRow>(
            primary: true,
            columns: _flowColumns,
            items: _statement?.rows ?? const [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _showFlowDetail,
            isLoading: _flowLoading && _statement == null,
            loadingMore: _flowLoading && _statement != null,
            error: _flowError,
            onRetry: () => _loadFlow(_flowPage),
            emptyMessage: '该时间范围内暂无账户流水',
            currentPage: _statement?.page ?? 1,
            totalPages: _statement?.totalPages ?? 1,
            onPageChange: _loadFlow,
          ),
        ),
      ],
    );
  }

  Widget _lockedFlow({required IconData icon, required String message}) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        primary: true,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: UtenEmpty(icon: icon, message: message),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flowFilters() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final search = UtenSearchBar(
            key: ValueKey('account-flow-search-$_searchEpoch'),
            hint: '搜索单号、对方单位或摘要',
            initialValue: _flowKeyword,
            onChanged: (value) => _flowKeyword = value,
          );
          final datesAndActions = Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dateButton(label: '起', value: _from, start: true),
              _dateButton(label: '止', value: _to, start: false),
              UtenButton(
                icon: Icons.search_rounded,
                onPressed: _flowLoading ? null : () => _loadFlow(1),
                child: const Text('查询'),
              ),
              UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.filter_alt_off_outlined,
                onPressed: _flowLoading
                    ? null
                    : () {
                        setState(() {
                          _flowKeyword = '';
                          _searchEpoch++;
                          _resetDates();
                        });
                        _loadFlow(1);
                      },
                child: const Text('清除'),
              ),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '账户流水（${_statement?.total ?? 0}）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (compact) ...[
                search,
                const SizedBox(height: UtenSpacing.s8),
                datesAndActions,
              ] else
                Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: UtenSpacing.s12),
                    datesAndActions,
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _dateButton({
    required String label,
    required DateTime value,
    required bool start,
  }) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.event_outlined, size: 18),
        label: Text('$label ${_date(value)}'),
        onPressed: _flowLoading
            ? null
            : () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: value,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked == null || !mounted) return;
                setState(() {
                  if (start) {
                    _from = picked;
                  } else {
                    _to = picked;
                  }
                });
              },
      ),
    );
  }
}

class _WarningValue {
  const _WarningValue(this.value);
  final String? value;
}
