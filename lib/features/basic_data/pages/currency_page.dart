// 币种资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与颜色/单位同级扁平字典（编号/名称/参考汇率/状态）。复刻 color_page：
// 标题行(Icon+Text+(N)+搜索+添加) + MasterDataTableView + showMasterEditDialog/DetailSheet。
// 查看全员可见（路由不设守卫），编辑按 currency:edit 显隐。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/currency_node.dart';
import '../models/master_facet.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class CurrencyPage extends ConsumerStatefulWidget {
  const CurrencyPage({super.key});

  @override
  ConsumerState<CurrencyPage> createState() => _CurrencyPageState();
}

class _CurrencyPageState extends ConsumerState<CurrencyPage> {
  PagedResult<CurrencyListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  CurrencyFacets? _facets;
  bool _detailLoading = false;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（code ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCurrencies(1);
      _loadFacets();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyStatus);

  Future<void> _loadCurrencies(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref
          .read(currencyRepositoryProvider)
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
        _error = '加载币种列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(currencyRepositoryProvider).facets();
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
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
    _loadCurrencies(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadCurrencies(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadCurrencies(1); // 排序变化回第 1 页重载
  }

  static const _fields = [
    MasterFieldDef(key: 'name', label: '币种名称', required: true, group: '基础'),
    MasterFieldDef(
      key: 'code',
      label: '币种编号',
      group: '基础',
      readOnly: true,
      hint: '保存后自动生成',
    ),
    MasterFieldDef(
      key: 'exchangeRate',
      label: '参考汇率',
      group: '基础',
      type: MasterFieldType.money,
      hint: '如 7.2',
    ),
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
  ];

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增币种',
      fields: _fields,
      initialValues: const {'status': '使用'},
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(currencyRepositoryProvider).create(body);
      },
      success: '币种已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadCurrencies(_pageNum);
    return true;
  }

  void _showEdit(CurrencyDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑币种',
      fields: _fields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'exchangeRate': d.exchangeRate?.toString() ?? '',
        'status': d.status ?? '',
      },
      readOnlyKeys: _canStatus && !d.baseCurrency ? null : const {'status'},
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(currencyRepositoryProvider).update(id, body);
      },
      success: '币种已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadCurrencies(_pageNum);
    return true;
  }

  Future<void> _toggleDetailStatus(CurrencyDetail d) async {
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: ApiEndpoints.currency(d.id), status: next),
      success: next == '禁用' ? '已停用' : '已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _loadCurrencies(_pageNum);
  }

  Future<void> _delete(CurrencyDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除币种'),
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该币种')}」吗？',
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
        await ref.read(currencyRepositoryProvider).delete(d.id);
      },
      success: '币种已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadCurrencies(_pageNum);
    if (mounted && _page != null && _page!.items.isEmpty && _page!.page > 1) {
      await _loadCurrencies(_page!.page - 1);
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
    CurrencyDetail? d;
    try {
      d = await ref.read(currencyRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载币种详情失败');
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
          : (detail.code ?? '币种详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      canDelete: _canDelete && !detail.baseCurrency,
      onToggleStatus: _canStatus && !detail.baseCurrency
          ? () => _toggleDetailStatus(detail)
          : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(CurrencyDetail c) => [
    MasterDetailRow('编号', c.code),
    MasterDetailRow('币种名称', c.name),
    MasterDetailRow('参考汇率', c.exchangeRate?.toStringAsFixed(4)),
    MasterDetailRow('状态', c.status),
    MasterDetailRow('本位币权威', c.baseCurrency ? '是(UUID 受保护)' : '否'),
    MasterDetailRow('旧系统 ID', c.legacyId?.toString()),
  ];

  static final _columns = <MasterColumnDef<CurrencyListItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (c) => c.code),
    MasterColumnDef(
      key: 'name',
      label: '币种名称',
      width: 200,
      value: (c) => c.name,
    ),
    MasterColumnDef(
      key: 'exchangeRate',
      label: '参考汇率',
      width: 140,
      type: 'money',
      sortable: true,
      value: (c) => c.exchangeRate?.toStringAsFixed(4),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (c) => c.status,
    ),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadCurrencies(1), _loadFacets()]);
  }

  /// 导出查询参数（与 _loadCurrencies 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(currencyRepositoryProvider)
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
    return Scaffold(
      appBar: UtenAppBar(
        title: '币种资料',
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
                        Icons.attach_money_rounded,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '币种 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索币种(名称/编号)',
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
                          child: const Text('添加币种'),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<CurrencyListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    toolbarActions: [
                      UtenPrintPreviewButton(
                        title: '币种资料',
                        subtitle: '最多前 2000 行',
                        loader: _printLoader,
                        exportEndpoint: '/master/currencies/export',
                        exportPermission: Perm.currencyExport,
                        exportReport: '',
                        exportQuery: _exportQuery,
                        exportFilename: '币种资料',
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                      UtenExportButton(
                        endpoint: '/master/currencies/export',
                        requiredPermission: Perm.currencyExport,
                        report: '',
                        queryParams: _exportQuery,
                        filename: '币种资料',
                        label: '导出币种',
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                    ],
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    onRowTap: (c) => _showDetail(c.id),
                    sortColumn: _sortKey,
                    sortAscending: _sortAsc,
                    onSortChange: _onSortChange,
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadCurrencies(_pageNum),
                    emptyMessage: '暂无币种',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _loadCurrencies(p),
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
