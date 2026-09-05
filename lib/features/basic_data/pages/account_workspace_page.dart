import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';
import '../models/currency_node.dart';
import '../models/master_facet.dart';
import '../models/payment_style_node.dart';
import '../repositories/account_repository.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/account_balance_reconciliation_dialog.dart';
import '../widgets/account_overview_card.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_edit_dialog.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key, this.initialAccountTypeFilter});

  final String? initialAccountTypeFilter;

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  PagedResult<AccountListItem>? _page;
  PagedResult<AccountListItem>? _disabledAccounts;
  AccountFacets? _facets;
  AccountSummary? _summary;
  final _listRequests = LatestRequestGuard();
  final _disabledListRequests = LatestRequestGuard();
  final _summaryRequests = LatestRequestGuard();

  int _pageNum = 1;
  bool _loading = false;
  bool _summaryLoading = false;
  bool _disabledLoading = false;
  bool _disabledRequested = false;
  bool _detailBusy = false;
  AccountListItem? _selectedAccount;
  String? _error;
  String? _summaryError;
  String? _disabledError;
  String _keyword = '';
  Map<String, String?> _filters = {};
  String? _sortKey;
  bool _sortAsc = true;

  List<MasterSelectOption> _currencyOptions = const [];
  Map<String, CurrencyListItem> _currencies = const {};
  List<MasterSelectOption> _styleOptions = const [];
  bool _stylesLoading = false;
  String? _stylesError;
  Future<bool>? _referenceOptionsFuture;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  bool get _isAdmin => ref.read(isSuperAdminProvider);
  bool get _canCreate => _isAdmin || _permissions.contains(Perm.accountCreate);
  bool get _canEdit => _isAdmin || _permissions.contains(Perm.accountEdit);
  bool get _canDelete => _isAdmin || _permissions.contains(Perm.accountDelete);
  bool get _canStatus => _isAdmin || _permissions.contains(Perm.accountStatus);
  bool get _canViewBalance =>
      _isAdmin || _permissions.contains(Perm.accountBalanceView);
  bool get _canAdjustBalance =>
      _canViewBalance &&
      (_isAdmin || _permissions.contains(Perm.accountBalanceAdjust));

  @override
  void initState() {
    super.initState();
    if (widget.initialAccountTypeFilter != null) {
      _filters = {'accountType': widget.initialAccountTypeFilter};
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  bool get _foldDisabledAccounts =>
      _keyword.trim().isEmpty && !_filters.containsKey('status');

  Map<String, String?> get _mainListFilters => {
    ..._filters,
    if (_foldDisabledAccounts) 'status': '使用',
  };

  Map<String, String?> get _disabledListFilters => {
    ..._filters,
    'status': '禁用',
  };

  Future<void> _loadDisabledAccounts({bool force = false}) async {
    if (!_foldDisabledAccounts) return;
    if (!force && (_disabledLoading || _disabledAccounts != null)) return;
    final generation = _disabledListRequests.begin();
    setState(() {
      _disabledRequested = true;
      _disabledLoading = true;
      _disabledError = null;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .list(
            size: 100,
            filters: _disabledListFilters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_disabledListRequests.isCurrent(generation)) return;
      setState(() {
        _disabledAccounts = result;
        _disabledLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || !_disabledListRequests.isCurrent(generation)) return;
      setState(() {
        _disabledError = error.message;
        _disabledLoading = false;
      });
    } catch (_) {
      if (!mounted || !_disabledListRequests.isCurrent(generation)) return;
      setState(() {
        _disabledError = '加载禁用账户失败，请重试';
        _disabledLoading = false;
      });
    }
  }

  Future<void> _loadAccounts(int page, {bool refreshDisabled = false}) async {
    final generation = _listRequests.begin();
    final disabledLoad =
        refreshDisabled && _disabledRequested && _foldDisabledAccounts
        ? _loadDisabledAccounts(force: true)
        : Future<void>.value();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .list(
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _mainListFilters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _page = result;
        final selectedId = _selectedAccount?.id;
        _selectedAccount = selectedId == null
            ? null
            : result.items.where((item) => item.id == selectedId).firstOrNull;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载账户列表失败';
        _loading = false;
      });
    } finally {
      await disabledLoad;
    }
  }

  Future<void> _loadFacets() async {
    try {
      final result = await ref.read(accountRepositoryProvider).facets();
      if (mounted) setState(() => _facets = result);
    } catch (_) {
      // 表头筛选是增强能力，失败不阻断主列表。
    }
  }

  Future<void> _loadSummary() async {
    if (!_canViewBalance) return;
    final generation = _summaryRequests.begin();
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    try {
      final result = await ref.read(accountRepositoryProvider).summary();
      if (!mounted || !_summaryRequests.isCurrent(generation)) return;
      setState(() {
        _summary = result;
        _summaryLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || !_summaryRequests.isCurrent(generation)) return;
      setState(() {
        _summaryError = error.message;
        _summaryLoading = false;
      });
    } catch (_) {
      if (!mounted || !_summaryRequests.isCurrent(generation)) return;
      setState(() {
        _summaryError = '账户余额概览加载失败';
        _summaryLoading = false;
      });
    }
  }

  Future<bool> _ensureReferenceOptions({bool force = false}) {
    if (!force &&
        _currencyOptions.isNotEmpty &&
        _styleOptions.isNotEmpty &&
        _stylesError == null) {
      return Future<bool>.value(true);
    }
    final pending = _referenceOptionsFuture;
    if (pending != null) return pending;
    final future = _loadReferenceOptions();
    _referenceOptionsFuture = future;
    return future;
  }

  Future<bool> _loadReferenceOptions() async {
    setState(() {
      _stylesLoading = true;
      _stylesError = null;
    });
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
      final currencyMap = {for (final item in currencies) item.id: item};
      setState(() {
        _currencies = currencyMap;
        _currencyOptions = [
          for (final item in currencies)
            MasterSelectOption(
              value: item.id,
              label:
                  financeCurrencyDisplayLabel(
                    name: item.name,
                    code: item.code,
                  ) ??
                  '未命名币种',
            ),
        ];
        _styleOptions = [
          for (final style in leaves)
            MasterSelectOption(
              value: style.id,
              label: style.code.isEmpty
                  ? style.name
                  : '${style.code} · ${style.name}',
            ),
        ];
        _stylesLoading = false;
        _stylesError = currencies.isEmpty
            ? '没有可用的币种资料'
            : leaves.isEmpty
            ? '没有可用的账户类末级会计科目'
            : null;
      });
      return _stylesError == null;
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _stylesLoading = false;
        _stylesError = '币种或会计科目加载失败，请重试';
      });
      return false;
    } finally {
      _referenceOptionsFuture = null;
    }
  }

  String _currencyLabel(String? id) {
    if (id == null) return '未设置币种';
    final currency = _currencies[id];
    return financeCurrencyDisplayLabel(
          name: currency?.name,
          code: currency?.code,
        ) ??
        '未设置币种';
  }

  String _accountCurrencyLabel(AccountListItem account) {
    final currency = account.currencyId == null
        ? null
        : _currencies[account.currencyId];
    return financeCurrencyDisplayLabel(
          name: account.currencyName ?? currency?.name,
          code: account.currencyCode ?? currency?.code,
        ) ??
        '未设置币种';
  }

  String _currencyFacetLabel(MasterFacetBucket bucket) {
    if (_currencies.containsKey(bucket.value)) {
      return _currencyLabel(bucket.value);
    }
    final serverLabel = bucket.label?.trim();
    if (serverLabel != null &&
        serverLabel.isNotEmpty &&
        serverLabel != bucket.value) {
      final parts = serverLabel.split('·');
      return financeCurrencyDisplayLabel(
            name: parts.last,
            code: parts.length > 1 ? parts.first : null,
          ) ??
          '未知币种';
    }
    return '未知币种';
  }

  Map<String, List<MasterFacetBucket>> get _labeledFacets {
    final source = _facets?.fields ?? const {};
    return {
      for (final entry in source.entries)
        entry.key: [
          for (final bucket in entry.value)
            MasterFacetBucket(
              value: bucket.value,
              count: bucket.count,
              label: switch (entry.key) {
                'accountType' => AccountType.labelOf(bucket.value),
                'currencyId' => _currencyFacetLabel(bucket),
                _ => bucket.display,
              },
            ),
        ],
    };
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      value == null ? next.remove(key) : next[key] = value;
      _filters = next;
    });
    _loadAccounts(1, refreshDisabled: _disabledRequested);
  }

  void _onKeywordChanged(String value) {
    setState(() => _keyword = value);
    _loadAccounts(1, refreshDisabled: _disabledRequested);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadAccounts(1, refreshDisabled: _disabledRequested);
  }

  List<MasterFieldDef> get _createFields => [
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
      hint: '留空自动生成；编号仅用于展示和检索，关系始终使用 UUID',
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
      required: true,
      group: '基础',
      type: MasterFieldType.select,
      options: _currencyOptions,
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

  Future<void> _showCreate() async {
    final referencesReady = await _ensureReferenceOptions();
    if (!mounted) return;
    if (!referencesReady) {
      context.appError(_stylesError ?? '币种或会计科目加载失败，请重试');
      return;
    }
    await showMasterEditDialog(
      context: context,
      title: '新增账户',
      fields: _createFields,
      initialValues: const {'accountType': 'BANK', 'status': '使用'},
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) async {
        final ok = await context.guardRun(
          () => ref.read(accountRepositoryProvider).create(body),
          success: '账户已创建',
          errorFallback: '创建失败，请稍后重试',
        );
        if (ok && mounted) await _refresh();
        return ok;
      },
    );
  }

  Future<void> _openAccount(String id, {bool edit = false}) async {
    if (_detailBusy) return;
    _detailBusy = true;
    try {
      await context.push(RoutePath.basicinfoAccountDetail(id, edit: edit));
    } finally {
      _detailBusy = false;
    }
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _toggleStatus(AccountListItem account) async {
    if (!_canStatus) return;
    final next = account.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: AccountEndpoints.one(account.id), status: next),
      success: next == '禁用' ? '账户已停用' : '账户已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _refresh();
  }

  Future<void> _delete(AccountListItem account) async {
    if (!_canDelete) return;
    final label = account.name?.isNotEmpty == true
        ? account.name!
        : (account.code ?? '该账户');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('确定删除「$label」吗？已有资金事实的账户会被服务端拒绝删除。'),
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
      () => ref.read(accountRepositoryProvider).delete(account.id),
      success: '账户已删除',
      errorFallback: '删除失败，请稍后重试',
    );
    if (deleted && mounted) await _refresh();
  }

  Future<void> _openBalanceReconciliation({
    String? accountId,
    bool compactOverride = false,
  }) async {
    if (!_canAdjustBalance) return;
    final result = await showAccountBalanceReconciliationDialog(
      context,
      initialAccountId: accountId,
      compactOverride: compactOverride ? true : null,
    );
    if (result == null || !mounted) return;
    context.appSuccess(
      '余额核对批次 ${result.batchNo ?? result.id} 已提交，'
      '更新 ${result.changedCount}/${result.itemCount} 个账户',
    );
    await _refresh();
  }

  List<UtenContextMenuEntry> _rowMenu(AccountListItem account) => [
    UtenMenuItem(
      label: '查看详情',
      icon: Icons.open_in_new_rounded,
      onTap: () => _openAccount(account.id),
    ),
    UtenMenuItem(
      label: '编辑账户',
      icon: Icons.edit_outlined,
      enabled: _canEdit,
      onTap: () => _openAccount(account.id, edit: true),
    ),
    UtenMenuItem(
      label: '余额校准',
      icon: Icons.fact_check_outlined,
      enabled: _canAdjustBalance,
      onTap: () => _openBalanceReconciliation(accountId: account.id),
    ),
    const UtenMenuDivider(),
    UtenMenuItem(
      label: account.status == '使用' ? '停用账户' : '启用账户',
      icon: account.status == '使用'
          ? Icons.pause_circle_outline_rounded
          : Icons.play_circle_outline_rounded,
      enabled: _canStatus,
      destructive: account.status == '使用',
      onTap: () => _toggleStatus(account),
    ),
    UtenMenuItem(
      label: '删除账户',
      icon: Icons.delete_outline_rounded,
      enabled: _canDelete,
      destructive: true,
      onTap: () => _delete(account),
    ),
  ];

  List<MasterColumnDef<AccountListItem>> get _columns => [
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 125,
      value: (account) => account.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '账户名称',
      width: 210,
      value: (account) => account.name,
    ),
    MasterColumnDef(
      key: 'accountType',
      label: '类型',
      width: 110,
      value: (account) => AccountType.labelOf(account.accountType),
    ),
    MasterColumnDef(
      key: 'currencyId',
      label: '币种',
      width: 130,
      value: _accountCurrencyLabel,
    ),
    MasterColumnDef(
      key: 'bankAccountNo',
      label: '银行账号',
      width: 190,
      value: (account) => account.bankAccountNo,
    ),
    if (_canViewBalance)
      MasterColumnDef(
        key: 'balanceCurrent',
        label: '当前余额',
        width: 150,
        type: 'money',
        sortable: true,
        value: (account) =>
            financeExactMoneyDisplay(account.balanceCurrentText),
      ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 95,
      value: (account) => account.status,
    ),
  ];

  List<MasterDataGroup<AccountListItem>> get _leadingGroups {
    final disabled = _disabledAccounts;
    final total = disabled?.total ?? _disabledFacetCount;
    if (!_foldDisabledAccounts ||
        (total == null && !_disabledRequested) ||
        (total == 0 && !_disabledLoading && _disabledError == null)) {
      return const <MasterDataGroup<AccountListItem>>[];
    }
    return [
      MasterDataGroup<AccountListItem>(
        id: 'disabled',
        title: total == null ? '禁用账户' : '禁用账户($total)',
        subtitle: '已停用账户，保留历史流水与财务引用',
        icon: Icons.block_rounded,
        tint: Colors.red.withValues(alpha: 0.12),
        items: disabled?.items ?? const <AccountListItem>[],
        total: total,
        detailLabel: disabled == null ? '点击加载' : '下拉查看详情',
        loading: _disabledLoading,
        error: _disabledError,
        onExpand: _loadDisabledAccounts,
        onRetry: () => _loadDisabledAccounts(force: true),
      ),
    ];
  }

  int? get _disabledFacetCount {
    final buckets = _facets?.fields['status'];
    if (buckets == null) return null;
    for (final bucket in buckets) {
      if (bucket.value == '禁用') return bucket.count;
    }
    return 0;
  }

  int get _safeTotal {
    final buckets =
        _facets?.fields['accountType'] ?? const <MasterFacetBucket>[];
    if (buckets.isNotEmpty) {
      return buckets.fold<int>(0, (sum, bucket) => sum + bucket.count) +
          (_facets?.nullCounts['accountType'] ?? 0);
    }
    return _page?.total ?? 0;
  }

  Map<String, dynamic> get _exportQuery => {
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_mainListFilters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(accountRepositoryProvider)
        .list(
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _mainListFilters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    final columns = _columns;
    return UtenPrintTable(
      headers: [for (final column in columns) column.label],
      rows: [
        for (final account in result.items)
          [for (final column in columns) column.value(account) ?? ''],
      ],
    );
  }

  Future<void> _refresh() async {
    await Future.wait([
      _loadAccounts(1, refreshDisabled: _disabledRequested),
      _loadFacets(),
      if (_canViewBalance) _loadSummary(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final filteredLabel = AccountType.byValue(
      widget.initialAccountTypeFilter,
    )?.label;
    final title = widget.initialAccountTypeFilter == null
        ? '账户资料'
        : '${filteredLabel ?? '账户'}账户';
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
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
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s4,
                      UtenSpacing.s8,
                      UtenSpacing.s4,
                      UtenSpacing.s12,
                    ),
                    child: AccountOverviewCard(
                      totalAccounts: _summary?.totalAccounts ?? _safeTotal,
                      canViewBalance: _canViewBalance,
                      summary: _summary,
                      loading: _summaryLoading,
                      error: _summaryError,
                      onRetry: _loadSummary,
                      filteredType: widget.initialAccountTypeFilter,
                    ),
                  ),
                  if (_stylesLoading || _stylesError != null)
                    AccountStyleLoadNotice(
                      loading: _stylesLoading,
                      error: _stylesError,
                      onRetry: () => _ensureReferenceOptions(force: true),
                    ),
                ],
              ),
              body: Column(
                children: [
                  _actionRow(),
                  Expanded(
                    child: MasterDataTableView<AccountListItem>(
                      primary: true,
                      showFullscreenToggle:
                          MediaQuery.sizeOf(context).width >= 600,
                      showColumnChooser:
                          MediaQuery.sizeOf(context).width >= 600,
                      columns: _columns,
                      items: _page?.items ?? const [],
                      leadingGroups: _leadingGroups,
                      toolbarActions: MediaQuery.sizeOf(context).width < 600
                          ? null
                          : [
                              UtenPrintPreviewButton(
                                title: '账户资料',
                                subtitle: '最多前 2000 行',
                                loader: _printLoader,
                                exportEndpoint: '/master/accounts/export',
                                exportPermission: Perm.accountExport,
                                exportReport: '',
                                exportQuery: _exportQuery,
                                exportFilename: '账户资料',
                                type: UtenButtonType.primary,
                                size: UtenButtonSize.large,
                              ),
                              UtenExportButton(
                                endpoint: '/master/accounts/export',
                                requiredPermission: Perm.accountExport,
                                report: '',
                                queryParams: _exportQuery,
                                filename: '账户资料',
                                label: '导出账户',
                                type: UtenButtonType.primary,
                                size: UtenButtonSize.large,
                              ),
                            ],
                      facets: _labeledFacets,
                      nullCounts: _facets?.nullCounts ?? const {},
                      filters: _filters,
                      onFilterChanged: _onFilterChanged,
                      rowColor: (account) => switch (account.status) {
                        '使用' => Colors.lightBlue.withValues(alpha: 0.11),
                        '禁用' => Colors.red.withValues(alpha: 0.09),
                        _ => null,
                      },
                      rowMenuBuilder: _rowMenu,
                      onSelectionChanged: (account) =>
                          setState(() => _selectedAccount = account),
                      onSelectionCleared: () =>
                          setState(() => _selectedAccount = null),
                      onRowTap: (account) => _openAccount(account.id),
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
                      onSortChange: _onSortChange,
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () =>
                          _loadAccounts(_pageNum, refreshDisabled: true),
                      emptyMessage: '暂无账户',
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      onPageChange: _loadAccounts,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionRow() {
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
          final heading = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_balance_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '账户（${_page?.total ?? 0}）',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.open_in_new_rounded,
                onPressed: _selectedAccount == null
                    ? null
                    : () => _openAccount(_selectedAccount!.id),
                child: const Text('打开选中账户'),
              ),
              if (_canAdjustBalance)
                UtenButton(
                  key: const ValueKey('account-balance-reconcile'),
                  type: UtenButtonType.secondary,
                  icon: Icons.fact_check_outlined,
                  onPressed: _openBalanceReconciliation,
                  child: const Text('余额核对'),
                ),
              if (_canCreate)
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.add_rounded,
                  onPressed: _showCreate,
                  child: const Text('添加账户'),
                ),
            ],
          );
          final search = UtenSearchBar(
            hint: '搜索账户（名称/编号/银行账号）',
            initialValue: _keyword,
            onChanged: _onKeywordChanged,
          );
          if (compact) {
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: UtenSpacing.s4),
                IconButton(
                  tooltip: '打开选中账户',
                  onPressed: _selectedAccount == null
                      ? null
                      : () => _openAccount(_selectedAccount!.id),
                  icon: const Icon(Icons.open_in_new_rounded),
                ),
                if (_canAdjustBalance)
                  IconButton(
                    key: const ValueKey('account-balance-reconcile-compact'),
                    tooltip: '余额核对',
                    onPressed: () =>
                        _openBalanceReconciliation(compactOverride: true),
                    icon: const Icon(Icons.fact_check_outlined),
                  ),
                if (_canCreate)
                  IconButton(
                    tooltip: '添加账户',
                    onPressed: _showCreate,
                    icon: const Icon(Icons.add_rounded),
                  ),
              ],
            );
          }
          return Row(
            children: [
              heading,
              const SizedBox(width: UtenSpacing.s12),
              Expanded(child: search),
              const SizedBox(width: UtenSpacing.s8),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class AccountStyleLoadNotice extends StatelessWidget {
  const AccountStyleLoadNotice({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(
          UtenSpacing.s4,
          0,
          UtenSpacing.s4,
          UtenSpacing.s8,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: error == null
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.errorContainer,
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.error_outline_rounded,
                color: theme.colorScheme.onErrorContainer,
              ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(error ?? '正在加载币种和会计科目…')),
            if (error != null)
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}
