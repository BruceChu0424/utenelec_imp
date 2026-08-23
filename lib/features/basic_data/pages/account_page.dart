// 账户资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 复刻 currency_page：编号/名称/银行账号/account_type(7 类)/币种/期初/累计收/累计付/当前余额/状态。
// account_type 用 select（7 类）；币种用 select（选项来自 currency 字典，本页 init 时加载）。
// 支持可选 [initialAccountTypeFilter]：钱流 hub「支票管理」入口预筛 CHECK/FOREIGN_CHECK（不单独模块）。
// 查看全员可见（路由不设守卫），编辑按 account:edit 显隐。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/account_node.dart';
import '../models/master_facet.dart';
import '../models/payment_style_node.dart';
import '../repositories/account_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/currency_repository.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key, this.initialAccountTypeFilter});

  /// 可选：进入时预筛的账户类型（如 'CHECK' 用于「支票管理」入口）。null = 不筛。
  final String? initialAccountTypeFilter;

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

/// 账户科目选项的非阻塞加载/错误状态，错误时提供就地重试。
class AccountStyleLoadNotice extends StatelessWidget {
  const AccountStyleLoadNotice({
    super.key,
    required this.loading,
    required this.onRetry,
    this.error,
  });

  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!loading && error == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final failed = error != null;
    return Semantics(
      liveRegion: true,
      label: failed ? error : '会计科目正在加载',
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(
          left: UtenSpacing.s4,
          right: UtenSpacing.s4,
          bottom: UtenSpacing.s8,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: failed
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
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
                size: 20,
                color: theme.colorScheme.onErrorContainer,
              ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                error ?? '正在加载可用会计科目…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: failed
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            if (failed)
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountPageState extends ConsumerState<AccountPage> {
  PagedResult<AccountListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  AccountFacets? _facets;
  bool _detailLoading = false;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（code ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  /// 币种字典（账户编辑表单币种下拉选项）。全局，失败静默降级为空下拉。
  List<MasterSelectOption> _currencyOptions = const [];

  /// 使用中的 ACCOUNT 末级科目。保存只提交 UUID，不向 legacy id 降级。
  List<MasterSelectOption> _accountStyleOptions = const [];
  bool _accountStylesLoading = false;
  String? _accountStylesError;

  @override
  void initState() {
    super.initState();
    if (widget.initialAccountTypeFilter != null) {
      _filters = {'accountType': widget.initialAccountTypeFilter};
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAccounts(1);
      _loadFacets();
      _loadCurrencyDict();
      _loadAccountStyles();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.accountCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.accountEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.accountDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.accountStatus);

  Future<void> _loadAccounts(int page) async {
    final generation = _loadRequests.begin();
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
            filters: _filters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载账户列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(accountRepositoryProvider).facets();
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  Future<void> _loadCurrencyDict() async {
    try {
      final list = await ref.read(currencyRepositoryProvider).dict();
      if (!mounted) return;
      setState(() {
        _currencyOptions = [
          for (final c in list)
            MasterSelectOption(
              value: c.id,
              label: (c.name != null && c.name!.isNotEmpty)
                  ? c.name!
                  : (c.code ?? c.id),
            ),
        ];
      });
    } catch (_) {
      // Currency options are optional; manual account editing still works.
    }
  }

  Future<void> _loadAccountStyles() async {
    if (_accountStylesLoading) return;
    setState(() {
      _accountStylesLoading = true;
      _accountStylesError = null;
    });
    try {
      final roots = await ref
          .read(paymentStyleRepositoryProvider)
          .tree(category: PaymentStyleCategory.account.value);
      final leaves = activeAccountStyleLeaves(roots);
      if (!mounted) return;
      setState(() {
        _accountStyleOptions = [
          for (final style in leaves)
            MasterSelectOption(
              value: style.id,
              label: style.code.isEmpty
                  ? style.name
                  : '${style.code} · ${style.name}',
            ),
        ];
        _accountStylesLoading = false;
        if (leaves.isEmpty) {
          _accountStylesError = '没有可用的账户类末级会计科目';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _accountStylesLoading = false;
        _accountStylesError = '会计科目加载失败，请重试';
      });
    }
  }

  bool _ensureAccountStylesReady() {
    if (_accountStyleOptions.isNotEmpty && _accountStylesError == null) {
      return true;
    }
    context.appError(_accountStylesError ?? '会计科目正在加载，请稍后再试');
    if (!_accountStylesLoading) _loadAccountStyles();
    return false;
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _loadAccounts(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadAccounts(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadAccounts(1); // 排序变化回第 1 页重载
  }

  List<MasterFieldDef> get _fields => [
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
      readOnly: true,
      hint: '保存后自动生成',
    ),
    const MasterFieldDef(key: 'bankAccountNo', label: '银行账号', group: '基础'),
    MasterFieldDef(
      key: 'accountType',
      label: '账户类型',
      required: true,
      group: '基础',
      type: MasterFieldType.select,
      options: [
        for (final t in AccountType.values)
          MasterSelectOption(value: t.value, label: t.label),
      ],
    ),
    MasterFieldDef(
      key: 'currencyId',
      label: '币种',
      group: '基础',
      type: MasterFieldType.select,
      options: _currencyOptions,
    ),
    MasterFieldDef(
      key: 'styleId',
      label: '会计科目',
      group: '基础',
      type: MasterFieldType.select,
      options: _accountStyleOptions,
      required: true,
      hint: '必须选择使用中的 ACCOUNT 末级科目（UUID 关联）',
    ),
    const MasterFieldDef(
      key: 'initBalance',
      label: '期初余额',
      group: '余额',
      type: MasterFieldType.money,
      hint: '如 0.00',
    ),
    const MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
  ];

  void _showCreate() {
    if (!_ensureAccountStylesReady()) return;
    showMasterEditDialog(
      context: context,
      title: '新增账户',
      fields: _fields,
      initialValues: const {'accountType': 'BANK', 'status': '使用'},
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(accountRepositoryProvider).create(body);
      },
      success: '账户已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadAccounts(_pageNum);
    return true;
  }

  void _showEdit(AccountDetail d) {
    if (!_ensureAccountStylesReady()) return;
    final styleAvailable =
        d.styleId != null &&
        _accountStyleOptions.any((option) => option.value == d.styleId);
    if (!styleAvailable) {
      context.appError('该账户缺少可用的会计科目 UUID，请重新选择后再保存');
    }
    showMasterEditDialog(
      context: context,
      title: '编辑账户',
      fields: _fields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'bankAccountNo': d.bankAccountNo ?? '',
        'accountType': d.accountType ?? '',
        'currencyId': d.currencyId ?? '',
        'styleId': styleAvailable ? d.styleId! : '',
        'initBalance': d.initBalance?.toString() ?? '',
        'status': d.status ?? '',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(accountRepositoryProvider).update(id, body);
      },
      success: '账户已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadAccounts(_pageNum);
    return true;
  }

  Future<void> _toggleDetailStatus(AccountDetail d) async {
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: AccountEndpoints.one(d.id), status: next),
      success: next == '禁用' ? '已停用' : '已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _loadAccounts(_pageNum);
  }

  Future<void> _delete(AccountDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户'),
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该账户')}」吗？',
        ),
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
    if (ok != true) return;
    if (!mounted) return;
    final deleted = await context.guardRun(
      () async {
        await ref.read(accountRepositoryProvider).delete(d.id);
      },
      success: '账户已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadAccounts(_pageNum);
    if (mounted && _page != null && _page!.items.isEmpty && _page!.page > 1) {
      await _loadAccounts(_page!.page - 1);
    }
  }

  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    AccountDetail? d;
    try {
      d = await ref.read(accountRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载账户详情失败');
    }
    if (!mounted) {
      nav.pop();
      return;
    }
    nav.pop();
    if (d == null) {
      _detailLoading = false;
      return;
    }
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '账户详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      canDelete: _canDelete,
      onToggleStatus: _canStatus ? () => _toggleDetailStatus(detail) : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(AccountDetail a) => [
    MasterDetailRow('编号', a.code),
    MasterDetailRow('账户名称', a.name),
    MasterDetailRow('银行账号', a.bankAccountNo),
    MasterDetailRow('账户类型', AccountType.labelOf(a.accountType)),
    MasterDetailRow(
      '会计科目',
      _accountStyleOptions
              .where((option) => option.value == a.styleId)
              .map((option) => option.label)
              .firstOrNull ??
          a.styleId ??
          '未关联（需重新选择）',
    ),
    MasterDetailRow('期初余额', a.initBalance?.toStringAsFixed(2)),
    MasterDetailRow('累计收款', a.receiptsTotal?.toStringAsFixed(2)),
    MasterDetailRow('累计付款', a.paymentsTotal?.toStringAsFixed(2)),
    MasterDetailRow('当前余额', a.balanceCurrent?.toStringAsFixed(2)),
    MasterDetailRow('状态', a.status),
    MasterDetailRow('自动建账', a.autoCreated ? '是' : '否'),
    MasterDetailRow('旧系统 ID', a.legacyId?.toString()),
  ];

  static final _columns = <MasterColumnDef<AccountListItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (a) => a.code),
    MasterColumnDef(
      key: 'name',
      label: '账户名称',
      width: 200,
      value: (a) => a.name,
    ),
    MasterColumnDef(
      key: 'accountType',
      label: '类型',
      width: 100,
      value: (a) => AccountType.labelOf(a.accountType),
    ),
    MasterColumnDef(
      key: 'bankAccountNo',
      label: '银行账号',
      width: 180,
      value: (a) => a.bankAccountNo,
    ),
    MasterColumnDef(
      key: 'balanceCurrent',
      label: '当前余额',
      width: 140,
      type: 'money',
      sortable: true,
      value: (a) => a.balanceCurrent?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (a) => a.status,
    ),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadAccounts(1), _loadFacets(), _loadAccountStyles()]);
  }

  /// 导出查询参数（与 _loadAccounts 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(accountRepositoryProvider)
        .list(
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    return UtenPrintTable(
      headers: [for (final c in _columns) c.label],
      rows: [
        for (final a in result.items)
          [for (final c in _columns) c.value(a) ?? ''],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    final title = widget.initialAccountTypeFilter == null
        ? '账户资料'
        : '${AccountType.byValue(widget.initialAccountTypeFilter)?.label ?? '账户'}账户';
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_balance_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '账户 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索账户（名称/编号/账号）',
                          initialValue: _keyword,
                          onChanged: _onKeywordChanged,
                        ),
                      ),
                      if (_canCreate) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: _showCreate,
                          child: const Text('添加账户'),
                        ),
                      ],
                    ],
                  ),
                ),
                AccountStyleLoadNotice(
                  loading: _accountStylesLoading,
                  error: _accountStylesError,
                  onRetry: _loadAccountStyles,
                ),
                Expanded(
                  child: MasterDataTableView<AccountListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    toolbarActions: [
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
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    onRowTap: (a) => _showDetail(a.id),
                    sortColumn: _sortKey,
                    sortAscending: _sortAsc,
                    onSortChange: _onSortChange,
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadAccounts(_pageNum),
                    emptyMessage: '暂无账户',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _loadAccounts(p),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
