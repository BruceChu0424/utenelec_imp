import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_field_suffix_icons.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/print/uten_print_preview.dart';
import 'package:collection/collection.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../components/print/complete_print_snapshot.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_navigation_session.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';
import '../models/currency_node.dart';
import '../models/master_facet.dart';
import '../models/master_batch.dart';
import '../models/payment_style_node.dart';
import '../repositories/account_repository.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/account_balance_reconciliation_dialog.dart';
import '../widgets/account_overview_card.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_inline_create_fields.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_batch_feedback.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key, this.initialAccountTypeFilter});

  final String? initialAccountTypeFilter;

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage>
    with
        MasterInlinePageMixin<AccountPage, AccountListItem>,
        ScopedPagedReadViewMixin<AccountPage> {
  final _readViewportRows = MasterDataTableRowsController<AccountListItem>();
  int get _visibleReadPage => _page == null
      ? (_pageNum)
      : (_readViewportRows.visiblePage ?? (_pageNum));

  @override
  void scopedPagedReadOwnerChanged() {
    if (mounted) {
      setState(() {
        inlineClearView();
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  @override
  String get inlineEntityType => 'accounts';
  @override
  bool get inlineCanEdit => _canEdit && !_batchBusy;
  @override
  bool get inlineReadReady => _page != null && !_loading && _error == null;
  @override
  String inlineIdOf(AccountListItem row) => row.id;
  @override
  Future<void> inlineReload() =>
      _loadAccounts(_visibleReadPage, refreshDisabled: _disabledRequested);
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _page = null;
    _disabledAccounts = null;
    _facets = null;
    _summary = null;
    _clearSelection();
    _commandEpoch++;
    _batchWriting = false;
    final dialogs = _batchDialogs.toList();
    _batchDialogs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in dialogs) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    });
    _error = null;
    _summaryError = null;
    _disabledError = null;
    _currencies = {};
    _currencyOptions = [];
    _styleOptions = [];
    _referenceOptionsFuture = null;
    _stylesError = null;
    _stylesLoading = false;
  }

  @override
  Map<String, MasterInlineField<AccountListItem>> get inlineFields => {
    'name': MasterInlineField(
      key: 'name',
      read: (row) => row.name,
      required: true,
    ),
    'bankAccountNo': MasterInlineField(
      key: 'bankAccountNo',
      read: (row) => row.bankAccountNo,
    ),
    'accountType': MasterInlineField(
      key: 'accountType',
      read: (row) => row.accountType,
      type: MasterFieldType.select,
      options: [
        for (final type in AccountType.values)
          MasterSelectOption(value: type.value, label: type.label),
      ],
      required: true,
    ),
    'currencyId': MasterInlineField(
      key: 'currencyId',
      read: (row) => row.currencyId,
      type: MasterFieldType.custom,
      cellBuilder: (context, row, field) => MasterInlineOptionsCell(
        field: field,
        currentLabel: row.currencyName,
        load: () async => [
          for (final currency
              in await ref.read(currencyRepositoryProvider).dict())
            MasterSelectOption(
              value: currency.id,
              label: currency.name ?? currency.code ?? currency.id,
            ),
        ],
      ),
    ),
  };
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
  final _navigation = PageNavigationSession();
  AccountListItem? _selectedAccount;
  Set<String> _selectedAccountIds = {};
  final Map<String, AccountListItem> _selectedAccounts = {};
  int _commandEpoch = 0;
  bool _batchBusy = false;
  bool _batchWriting = false;
  String _batchAction = '';
  final Set<ModalRoute<dynamic>> _batchDialogs = {};
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

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
    final inlineReadBoundary = captureInlineRead();
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
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_disabledListRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _disabledAccounts = result;
        _disabledLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_disabledListRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _disabledError = error.message;
        _disabledLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_disabledListRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _disabledError = '加载禁用账户失败，请重试';
        _disabledLoading = false;
      });
    }
  }

  Future<void> _loadAccounts(
    int page, {
    bool refreshDisabled = false,
    bool useCache = false,
  }) async {
    final inlineReadBoundary = captureInlineRead();
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
    final repository = ref.read(accountRepositoryProvider);
    final keyword = _keyword.trim().isEmpty ? null : _keyword;
    final filters = Map<String, String?>.unmodifiable(_mainListFilters);
    final sort = _sortKey;
    final order = sort == null ? null : (_sortAsc ? 'asc' : 'desc');
    Object pagingQuery() => [
      ref.read(accountRepositoryProvider),
      _keyword,
      _mainListFilters,
      _sortKey,
      _sortAsc,
    ];
    try {
      final result = await readScopedPage<AccountListItem>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) => repository.list(
          page: target,
          keyword: keyword,
          filters: filters,
          sort: sort,
          order: order,
        ),
      );
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_listRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _page = result;
        for (final item in result.items) {
          if (_selectedAccountIds.contains(item.id)) {
            _selectedAccounts[item.id] = item;
          }
        }
        _selectedAccount = _selectedAccountIds.length == 1
            ? _selectedAccounts[_selectedAccountIds.single]
            : null;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_listRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_listRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = '加载账户列表失败';
        _loading = false;
      });
    } finally {
      await disabledLoad;
    }
  }

  Future<void> _loadFacets() async {
    final inlineReadBoundary = captureInlineRead();
    try {
      final result = await ref.read(accountRepositoryProvider).facets();
      if (inlineAcceptsRead(inlineReadBoundary)) {
        setState(() => _facets = result);
      }
    } catch (_) {
      // 表头筛选是增强能力，失败不阻断主列表。
    }
  }

  Future<void> _loadSummary() async {
    final inlineReadBoundary = captureInlineRead();
    if (!_canViewBalance) return;
    final generation = _summaryRequests.begin();
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    try {
      final result = await ref.read(accountRepositoryProvider).summary();
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_summaryRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _summary = result;
        _summaryLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_summaryRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _summaryError = error.message;
        _summaryLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_summaryRequests.isCurrent(generation)) {
        return;
      }
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
    final boundary = captureInlineRead();
    // Inline choice cells can request these references while their parent is
    // building. Start the loading-state update after that build, retaining the
    // caller's read owner across the deferred start.
    final future = Future<bool>.microtask(() {
      if (!mounted || !inlineAcceptsRead(boundary)) return false;
      return _loadReferenceOptions(boundary);
    });
    _referenceOptionsFuture = future;
    return future;
  }

  Future<bool> _loadReferenceOptions(
    MasterInlineReadToken inlineReadBoundary,
  ) async {
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
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return false;
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
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return false;
      setState(() {
        _stylesLoading = false;
        _stylesError = '币种或会计科目加载失败，请重试';
      });
      return false;
    } finally {
      if (inlineAcceptsRead(inlineReadBoundary)) _referenceOptionsFuture = null;
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
      _clearSelection();
      _commandEpoch++;
      final next = Map<String, String?>.from(_filters);
      value == null ? next.remove(key) : next[key] = value;
      _filters = next;
    });
    _loadAccounts(1, refreshDisabled: _disabledRequested);
  }

  void _onKeywordChanged(String value) {
    setState(() {
      _clearSelection();
      _commandEpoch++;
      _keyword = value;
    });
    _loadAccounts(1, refreshDisabled: _disabledRequested);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _clearSelection();
      _commandEpoch++;
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
      hint: '留空自动生成；编号只用于展示和查找，不影响系统内部关联',
      identifierDomain: 'ACCOUNT',
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
      hint: '必须选择使用中的最末级会计科目',
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
    final inlineReadBoundary = captureInlineRead();
    final referencesReady = await _ensureReferenceOptions();
    if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return;
    if (!referencesReady) {
      context.appError(_stylesError ?? '币种或会计科目加载失败，请重试');
      return;
    }
    await showMasterEditDialog(
      context: context,
      draftSpec: FormDraftCatalog.account.spec(title: '新增账户'),
      title: '新增账户',
      fields: _createFields,
      initialValues: const {'accountType': 'BANK', 'status': '使用'},
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) async {
        await ref.read(accountRepositoryProvider).create(body);
        if (mounted) {
          context.appSuccess('账户已创建');
          await _refresh();
        }
        return true;
      },
    );
  }

  @override
  MasterInlineCreateConfig get inlineCreation => MasterInlineCreateConfig(
    namespace: 'accounts',
    fields: masterInlineCreateFields(
      _createFields,
      excluded: {if (!_canStatus) 'status'},
      options: {
        'currencyId': () async {
          if (!await _ensureReferenceOptions()) {
            throw StateError('币种或会计科目加载失败，请重试');
          }
          return _currencyOptions;
        },
        'styleId': () async {
          if (!await _ensureReferenceOptions()) {
            throw StateError('会计科目加载失败，请重试');
          }
          return _styleOptions;
        },
      },
    ),
    defaults: const {'accountType': 'BANK', 'status': '使用'},
    canCreate: _canCreate,
    onCreate: (_, values) async {
      await ref.read(accountRepositoryProvider).create({
        'accountType': 'BANK',
        'status': '使用',
        ...values,
      });
    },
  );

  Future<void> _openAccount(String id, {bool edit = false}) async {
    if (_batchBusy) return;
    if (!await inlineEdit.confirmLeave(context) || !mounted) return;
    if (_detailBusy) return;
    _detailBusy = true;
    try {
      await _navigation.push(RoutePath.basicinfoAccountDetail(id, edit: edit));
    } finally {
      _detailBusy = false;
    }
    if (!mounted) return;
    await _refresh();
  }

  void _clearSelection() {
    _selectedAccountIds = {};
    _selectedAccounts.clear();
    _selectedAccount = null;
  }

  void _selectAccounts(Set<String> ids) {
    if (_batchBusy) return;
    setState(() {
      _selectedAccountIds = Set.of(ids);
      for (final account in [...?_page?.items, ...?_disabledAccounts?.items]) {
        if (ids.contains(account.id)) _selectedAccounts[account.id] = account;
      }
      _selectedAccounts.removeWhere((id, _) => !ids.contains(id));
      _selectedAccount = ids.length == 1 ? _selectedAccounts[ids.single] : null;
    });
  }

  String _accountLabel(AccountListItem account) =>
      account.name?.isNotEmpty == true ? account.name! : (account.code ?? '账户');

  Future<void> _toggleStatus(AccountListItem account) => _runAccountBatch(
    {account.id},
    status: account.status == '使用' ? '禁用' : '使用',
    account: account,
  );

  Future<void> _delete(AccountListItem account) =>
      _runAccountBatch({account.id}, account: account);

  Future<T?> _ownedBatchDialog<T>(
    SensitiveReadBoundary owner,
    int epoch,
    WidgetBuilder builder,
  ) async {
    ModalRoute<T>? route;
    try {
      return await showDialog<T>(
        context: context,
        builder: (dialogContext) {
          route = ModalRoute.of<T>(dialogContext);
          if (route != null) _batchDialogs.add(route!);
          return Consumer(
            builder: (context, ref, _) {
              final boundary = ref.watch(sensitiveReadBoundaryProvider);
              if (owner != boundary || epoch != _commandEpoch) {
                return const SizedBox.shrink();
              }
              return builder(context);
            },
          );
        },
      );
    } finally {
      _batchDialogs.remove(route);
    }
  }

  Future<bool> _confirmBatch(
    SensitiveReadBoundary owner,
    int epoch, {
    required List<String> targets,
    required Map<String, String> labels,
    String? status,
  }) async {
    final l10n = AppLocalizations.of(context);
    final deleting = status == null;
    final disabling = status == '禁用';
    final label = targets.length == 1 ? labels[targets.single]! : '选中的账户';
    final title = deleting
        ? targets.length == 1
              ? '删除账户'
              : '批量删除账户'
        : disabling
        ? l10n.masterStatusDisableTitle
        : l10n.masterStatusEnableTitle;
    final description = deleting
        ? targets.length == 1
              ? '确定删除「$label」吗？已有资金往来的账户不能删除。'
              : '确定删除选中的 ${targets.length} 个账户吗？已有资金往来的账户不能删除，未通过校验的账户会列出原因并保留。'
        : disabling
        ? l10n.masterStatusDisableBody(label, targets.length)
        : l10n.masterStatusEnableBody(label, targets.length);
    return await _ownedBatchDialog<bool>(
          owner,
          epoch,
          (context) => UtenAlertDialog(
            title: UtenDialogHeading(
              title: Text(title),
              icon: deleting
                  ? Icons.delete_outline_rounded
                  : Icons.power_settings_new,
              danger: deleting || disabling,
            ),
            content: Text(description),
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel),
              ),
              UtenButton(
                type: deleting || disabling
                    ? UtenButtonType.danger
                    : UtenButtonType.primary,
                onPressed: () => Navigator.pop(context, true),
                child: Text(deleting ? '删除' : l10n.commonConfirm),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _showBatchOutcome(
    MasterBatchResult result,
    String action,
    SensitiveReadBoundary owner,
    int epoch,
  ) async {
    if (result.failed == 0) {
      await showMasterBatchOutcome(context, result, action: action, noun: '账户');
      return;
    }
    await _ownedBatchDialog<void>(
      owner,
      epoch,
      (context) => SelectionArea(
        child: UtenAlertDialog(
          key: const Key('master-batch-outcome'),
          scrollable: false,
          title: Text(
            result.succeeded == 0
                ? '$action失败：${result.failed} 个账户没有处理'
                : '已$action ${result.succeeded} 个，${result.failed} 个没有处理',
          ),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final failure in result.failures)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            failure.label ?? '账户',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(failure.reason ?? '处理失败'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            UtenButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAccountBatch(
    Set<String> ids, {
    String? status,
    AccountListItem? account,
  }) async {
    if (_batchBusy ||
        ids.isEmpty ||
        (status == null ? !_canDelete : !_canStatus)) {
      return;
    }
    final epoch = _commandEpoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final ownerRoute = ModalRoute.of(context);
    final targets = ids.toList()..sort();
    final labels = {
      for (final id in targets)
        id: account?.id == id
            ? _accountLabel(account!)
            : _selectedAccounts[id] == null
            ? '账户'
            : _accountLabel(_selectedAccounts[id]!),
    };
    final action = status == null
        ? '删除'
        : status == '禁用'
        ? '停用'
        : '启用';
    bool current() =>
        mounted &&
        epoch == _commandEpoch &&
        ref.read(sensitiveReadBoundaryProvider) == boundary &&
        (ownerRoute == null ||
            ownerRoute.isCurrent ||
            _batchDialogs.any((route) => route.isCurrent)) &&
        (status == null ? _canDelete : _canStatus);
    // The unsaved-edit decision belongs to the editor, before any batch busy
    // state changes its fields or captures a sensitive write request.
    if (!await inlineEdit.confirmLeave(context) ||
        !mounted ||
        _batchBusy ||
        !current()) {
      return;
    }
    setState(() {
      _batchBusy = true;
      _batchAction = action;
    });
    MasterBatchResult? result;
    try {
      result = await runSensitiveWrite<MasterBatchResult?>(
        ref,
        isCurrent: current,
        write: () async {
          if (inlineEdit.active || inlineEdit.dirty || !current()) {
            return null;
          }
          final confirmed = await _confirmBatch(
            boundary,
            epoch,
            targets: targets,
            labels: labels,
            status: status,
          );
          if (!confirmed || !current()) return null;
          if (inlineEdit.active || inlineEdit.dirty) return null;
          setState(() => _batchWriting = true);
          final results = <MasterBatchItemResult>[];
          for (var index = 0; index < targets.length; index++) {
            if (!current()) throw AuthenticatedRequestScope.changed();
            final id = targets[index];
            try {
              if (status == null) {
                await ref.read(accountRepositoryProvider).delete(id);
              } else {
                await ref
                    .read(masterStatusRepositoryProvider)
                    .change(
                      resourcePath: AccountEndpoints.one(id),
                      status: status,
                    );
              }
              if (!current()) throw AuthenticatedRequestScope.changed();
              results.add(
                MasterBatchItemResult(id: id, label: labels[id], ok: true),
              );
            } catch (error) {
              if (!current() || isSessionBoundaryError(error)) rethrow;
              results.add(
                MasterBatchItemResult(
                  id: id,
                  label: labels[id],
                  ok: false,
                  reason: error is ApiException
                      ? masterBatchFailureReason(error)
                      : '处理失败，请刷新后核对该账户',
                ),
              );
              if (error is ApiException &&
                  (error.httpStatus == 401 || error.httpStatus == 403)) {
                for (final pending in targets.skip(index + 1)) {
                  results.add(
                    MasterBatchItemResult(
                      id: pending,
                      label: labels[pending],
                      ok: false,
                      reason: '权限或登录状态已变化，该账户尚未处理',
                    ),
                  );
                }
                break;
              }
            }
          }
          return MasterBatchResult(
            succeeded: results.where((item) => item.ok).length,
            failed: results.where((item) => !item.ok).length,
            results: results,
          );
        },
      );
    } catch (error) {
      if (mounted && current()) context.appApiError(error);
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _batchWriting = false;
        });
      }
    }
    if (result == null || !current()) return;
    final failed = result.failures.map((item) => item.id).toSet();
    setState(() {
      _selectedAccountIds = failed;
      _selectedAccounts.removeWhere((id, _) => !failed.contains(id));
      _selectedAccount = failed.length == 1
          ? _selectedAccounts[failed.single]
          : null;
    });
    await _refresh(preserveSelection: true);
    if (!mounted || !current()) return;
    await _showBatchOutcome(result, action, boundary, epoch);
  }

  Future<void> _openBalanceReconciliation({
    String? accountId,
    bool compactOverride = false,
  }) async {
    if (_batchBusy) return;
    if (!await inlineEdit.confirmLeave(context) || !mounted) return;
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

  List<UtenContextMenuEntry> _rowMenu(AccountListItem account) {
    if (_selectedAccountIds.length > 1 &&
        _selectedAccountIds.contains(account.id)) {
      final ids = Set<String>.of(_selectedAccountIds);
      return [
        if (_canStatus) ...[
          UtenMenuItem(
            label: '停用选中(${ids.length})',
            icon: Icons.pause_circle_outline_rounded,
            destructive: true,
            enabled: !_batchBusy,
            preserveSelectionAfterAction: true,
            onTap: () => _runAccountBatch(ids, status: '禁用'),
          ),
          UtenMenuItem(
            label: '启用选中(${ids.length})',
            icon: Icons.play_circle_outline_rounded,
            enabled: !_batchBusy,
            preserveSelectionAfterAction: true,
            onTap: () => _runAccountBatch(ids, status: '使用'),
          ),
        ],
        if (_canDelete)
          UtenMenuItem(
            label: '删除选中(${ids.length})',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            enabled: !_batchBusy,
            preserveSelectionAfterAction: true,
            onTap: () => _runAccountBatch(ids),
          ),
      ];
    }
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        enabled: !_batchBusy,
        onTap: () => _openAccount(account.id),
      ),
      UtenMenuItem(
        label: '编辑账户',
        icon: Icons.edit_outlined,
        enabled: _canEdit && !_batchBusy,
        onTap: () => _openAccount(account.id, edit: true),
      ),
      UtenMenuItem(
        label: '余额校准',
        icon: Icons.fact_check_outlined,
        enabled: _canAdjustBalance && !_batchBusy,
        onTap: () => _openBalanceReconciliation(accountId: account.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: account.status == '使用' ? '停用账户' : '启用账户',
        icon: account.status == '使用'
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _canStatus && !_batchBusy,
        destructive: account.status == '使用',
        preserveSelectionAfterAction: true,
        onTap: () => _toggleStatus(account),
      ),
      UtenMenuItem(
        label: '删除账户',
        icon: Icons.delete_outline_rounded,
        enabled: _canDelete && !_batchBusy,
        destructive: true,
        preserveSelectionAfterAction: true,
        onTap: () => _delete(account),
      ),
    ];
  }

  List<Widget> _accountFloatingActions(
    BuildContext context,
    Set<String> ids,
  ) => [
    MasterInlineEditActions<AccountListItem>(
      controller: inlineEdit,
      canEdit: _canEdit && inlineReadReady && !_batchBusy,
      canCreate: _canCreate && inlineReadReady && !_batchBusy,
      onSave: saveInline,
      embedded: true,
      additionalActions: [
        if (ids.isNotEmpty && _canStatus) ...[
          UtenButton(
            key: const Key('account-batch-disable'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _batchBusy || _loading
                ? null
                : () => _runAccountBatch(Set.of(ids), status: '禁用'),
            child: const Text('停用选中'),
          ),
          UtenButton(
            key: const Key('account-batch-enable'),
            type: UtenButtonType.tonal,
            size: UtenButtonSize.large,
            onPressed: _batchBusy || _loading
                ? null
                : () => _runAccountBatch(Set.of(ids), status: '使用'),
            child: const Text('启用选中'),
          ),
        ],
        if (ids.isNotEmpty && _canDelete)
          UtenButton(
            key: const Key('account-batch-delete'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _batchBusy || _loading
                ? null
                : () => _runAccountBatch(Set.of(ids)),
            child: const Text('删除选中'),
          ),
        if (_canCreate)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: _batchBusy ? null : () => inlineNavigate(_showCreate),
            child: const Text('添加账户'),
          ),
      ],
    ),
  ];

  List<MasterColumnDef<AccountListItem>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (account) => account.status,
    ),
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 125,
      sortable: true,
      value: (account) => account.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '账户名称',
      width: 210,
      sortable: true,
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
      sortable: true,
      value: (account) => account.bankAccountNo,
    ),
    if (_canViewBalance)
      MasterColumnDef(
        key: 'balanceCurrent',
        label: '当前余额',
        width: 150,
        type: 'money',
        sortable: true,
        columnSearchEnabled: true,
        exactValueOf: (account) => account.balanceCurrentText,
        info: '按账户原币余额的原始精度检索；不同币种不合计',
        value: (account) =>
            financeExactMoneyDisplay(account.balanceCurrentText),
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
        icon: Icons.block_rounded,
        // 停用分组=灰档淡底（ADR-169：停用归中性终态，原浅红把「已停用」
        // 当异常——保留历史引用是正常业务形态）。
        tint: UtenColors.statusNeutral.withValues(alpha: 0.12),
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
    ...masterFilterQueryParams(_mainListFilters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  Map<String, dynamic> get _exportBody => {
    'sensitiveFilter': contactSensitiveFilterBody(
      _mainListFilters,
      keyword: _keyword,
    ),
  };

  Future<UtenPrintTable> _printLoader() async {
    final repository = ref.read(accountRepositoryProvider);
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final version = _commandEpoch;
    final query = Map<String, dynamic>.of(_exportQuery);
    final filters = Map<String, String?>.unmodifiable(_mainListFilters);
    final keyword = _keyword.trim().isEmpty ? null : _keyword;
    final sort = _sortKey;
    final order = sort == null ? null : (_sortAsc ? 'asc' : 'desc');
    final columns = List.of(_columns);
    var retired = false;
    bool current() {
      if (retired || !mounted) return false;
      retired =
          version != _commandEpoch ||
          epoch != ref.read(exportContextEpochProvider) ||
          boundary != ref.read(sensitiveReadBoundaryProvider) ||
          !const DeepCollectionEquality().equals(query, _exportQuery);
      return !retired;
    }

    final scope = await boundary.api.captureRequestScope(isCurrent: current);
    final table = await scope.run(
      () => loadCompletePrintSnapshot(
        loadPage: (page, size) => repository.list(
          page: page,
          size: size,
          keyword: keyword,
          filters: filters,
          sort: sort,
          order: order,
        ),
        idOf: (row) => row.id,
        headers: [for (final column in columns) column.label],
        columnKeys: [for (final column in columns) column.key],
        cellsOf: (row) => [
          for (final column in columns) column.value(row) ?? '',
        ],
        isCurrent: () => current() && scope.isCurrent,
      ),
    );
    await scope.verify();
    return table;
  }

  Future<void> _refresh({bool preserveSelection = false, int? page}) async {
    if (!preserveSelection) {
      setState(() {
        _clearSelection();
        _commandEpoch++;
      });
    }
    await Future.wait([
      _loadAccounts(page ?? 1, refreshDisabled: _disabledRequested),
      _loadFacets(),
      if (_canViewBalance) _loadSummary(),
    ]);
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.account,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final filteredLabel = AccountType.byValue(
      widget.initialAccountTypeFilter,
    )?.label;
    final title = widget.initialAccountTypeFilter == null
        ? '账户资料'
        : '${filteredLabel ?? '账户'}账户';
    return Stack(
      children: [
        inlineGuard(
          Scaffold(
            appBar: UtenAppBar(
              title: title,
              leading: UtenBackButton(
                onPressed: () => inlineNavigate(
                  () => backTo(context, defaultPath: RouteName.basicinfo),
                ),
              ),
              actions: [
                MasterOperationHistoryActions(
                  entityType: 'accounts',
                  onChanged: _refresh,
                ),
                UtenRefreshButton(
                  busy: _loading,
                  onRefresh: () =>
                      inlineNavigate(() => _refresh(page: _visibleReadPage)),
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
                        UtenPageEdgePadding(
                          padding: const EdgeInsets.fromLTRB(
                            UtenSpacing.s4,
                            UtenSpacing.s8,
                            UtenSpacing.s4,
                            UtenSpacing.s12,
                          ),
                          child: AccountOverviewCard(
                            totalAccounts:
                                _summary?.totalAccounts ?? _safeTotal,
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
                            rowsController: _readViewportRows,
                            expensiveRowMounts: inlineEdit.active,
                            appendRowsSource: inlineAppendRowsSource,
                            bottomContentPadding:
                                (_canCreate ||
                                    _canEdit ||
                                    _canStatus ||
                                    _canDelete)
                                ? UtenFloatingActionGroup.scrollClearance
                                : 0,
                            columnEditingEnabled: _canEdit,
                            tableKey:
                                'features.basic_data.pages.account_workspace_page.AccountPageState._buildDraftHost.1',
                            primary: true,
                            showFullscreenToggle:
                                MediaQuery.sizeOf(context).width >= 600,
                            showColumnChooser:
                                MediaQuery.sizeOf(context).width >= 600,
                            columns: inlineColumns(_columns),
                            serverColumnSearchKeys: {
                              'code',
                              'name',
                              'bankAccountNo',
                              if (_canViewBalance) 'balanceCurrent',
                            },
                            headerFilterScopeDescription:
                                '检索当前账户范围的完整结果；余额按各账户原币检索',
                            items: _page?.items ?? const [],
                            selectable: true,
                            idOf: (account) => account.id,
                            selectedIds: _selectedAccountIds,
                            onSelectedIdsChanged: _selectAccounts,
                            batchActionsBuilder: _accountFloatingActions,
                            leadingGroups: _leadingGroups,
                            // 导出/打印进左簇（2026-10-18 用户口径）：与「表头设置 / 全屏」同排靠左，
                            // 工具条右侧留给分页；按钮纯文字无 icon（工具条无 icon 口径）。
                            toolbarLeadingActions:
                                MediaQuery.sizeOf(context).width < 600
                                ? null
                                : [
                                    UtenPrintPreviewButton(
                                      title: '账户资料',
                                      subtitle: '当前筛选的完整结果',
                                      loader: _printLoader,
                                      exportEndpoint: '/master/accounts/export',
                                      exportPermission: Perm.accountExport,
                                      exportReport: '',
                                      exportQuery: _exportQuery,
                                      exportBody: _exportBody,
                                      exportFilename: '账户资料',
                                      type: UtenButtonType.primary,
                                      size: UtenButtonSize.large,
                                      icon: null,
                                    ),
                                    UtenExportButton(
                                      endpoint: '/master/accounts/export',
                                      requiredPermission: Perm.accountExport,
                                      report: '',
                                      queryParams: _exportQuery,
                                      bodyParams: _exportBody,
                                      filename: '账户资料',
                                      label: '导出账户',
                                      type: UtenButtonType.primary,
                                      size: UtenButtonSize.large,
                                      icon: null,
                                    ),
                                  ],
                            facets: _labeledFacets,
                            nullCounts: _facets?.nullCounts ?? const {},
                            filters: _filters,
                            onFilterChanged: (key, value) => inlineNavigate(
                              () => _onFilterChanged(key, value),
                            ),
                            // 行底色按状态（ADR-169 收编）：使用=蓝档淡底（裸色收编）/
                            // 禁用=灰档淡底（停用归中性终态，原浅红当异常色）。
                            rowColor: (account) => switch (account.status) {
                              '使用' => UtenColors.info.withValues(alpha: 0.11),
                              '禁用' => UtenColors.statusNeutral.withValues(
                                alpha: 0.09,
                              ),
                              _ => null,
                            },
                            rowMenuBuilder: inlineEdit.active ? null : _rowMenu,
                            onRowTap: inlineEdit.active
                                ? null
                                : (account) => _openAccount(account.id),
                            sortColumn: _sortKey,
                            sortAscending: _sortAsc,
                            onSortChange: (key, ascending) => inlineNavigate(
                              () => _onSortChange(key, ascending),
                            ),
                            isLoading: _loading && _page == null,
                            loadingMore: _loading && _page != null,
                            error: _error,
                            onRetry: () => _loadAccounts(
                              _visibleReadPage,
                              refreshDisabled: true,
                            ),
                            emptyMessage: '暂无账户',
                            currentPage: _page?.page ?? 1,
                            totalPages: _page?.totalPages ?? 1,
                            paginationScope: (
                              _keyword,
                              _filters.toString(),
                              _sortKey,
                              _sortAsc,
                            ),
                            onPageChange: (page) => inlineNavigate(
                              () => _loadAccounts(page, useCache: true),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_batchWriting)
          UtenBusyOverlay(
            showDoNotLeaveHint: false,
            title: '正在$_batchAction账户',
            description: '逐项校验并处理选中的账户',
            semanticsKey: const Key('account-batch-writing'),
          ),
      ],
    );
  }

  Widget _actionRow() {
    return UtenPageEdgePadding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        0,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
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
            ],
          );
          final search = UtenSearchBar(
            hint: '搜索账户（名称/编号/银行账号）',
            initialValue: _keyword,
            onChanged: (value) =>
                inlineNavigate(() => _onKeywordChanged(value)),
          );
          if (compact) {
            return Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: UtenSpacing.s4),
                UtenFieldSuffixIcons(
                  children: [
                    IconButton(
                      tooltip: '打开选中账户',
                      onPressed: _selectedAccount == null
                          ? null
                          : () => _openAccount(_selectedAccount!.id),
                      icon: const Icon(Icons.open_in_new_rounded),
                    ),
                    if (_canAdjustBalance)
                      IconButton(
                        key: const ValueKey(
                          'account-balance-reconcile-compact',
                        ),
                        tooltip: '余额核对',
                        onPressed: () =>
                            _openBalanceReconciliation(compactOverride: true),
                        icon: const Icon(Icons.fact_check_outlined),
                      ),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
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
