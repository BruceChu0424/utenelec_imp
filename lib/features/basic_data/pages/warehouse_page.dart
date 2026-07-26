// 仓库资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 复刻 color_page：编号/名称/位置/核算/状态。accountable(bool) 用 select 使用/不使用
// （提交 'true'/'false' 字符串，Jackson 自动转 Boolean）。查看全员可见，编辑按 warehouse:edit。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/warehouse_node.dart';
import '../repositories/warehouse_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class WarehousePage extends ConsumerStatefulWidget {
  const WarehousePage({super.key});

  @override
  ConsumerState<WarehousePage> createState() => _WarehousePageState();
}

class _WarehousePageState extends ConsumerState<WarehousePage> {
  PagedResult<WarehouseListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;

  Map<String, String?> _filters = {};
  String _keyword = '';
  WarehouseFacets? _facets;
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWarehouses(1);
      _loadFacets();
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.warehouseEdit);

  Future<void> _loadWarehouses(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref.read(warehouseRepositoryProvider).list(
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
          );
      if (!mounted) return;
      setState(() {
        _page = result;
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
        _error = '加载仓库列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(warehouseRepositoryProvider).facets();
      if (!mounted) return;
      setState(() => _facets = f);
    } on ApiException catch (e) {
      debugPrint('warehouse facets load failed: ${e.message}');
    } catch (_) {
      debugPrint('warehouse facets load failed');
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
    _loadWarehouses(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadWarehouses(1);
  }

  static const _fields = [
    MasterFieldDef(
        key: 'name', label: '仓库名称', required: true, group: '基础'),
    MasterFieldDef(key: 'code', label: '仓库编号', group: '基础'),
    MasterFieldDef(
        key: 'location',
        label: '仓库位置',
        group: '基础',
        hint: '如 总仓库/轨道仓'),
    MasterFieldDef(
        key: 'accountable',
        label: '是否核算',
        group: '基础',
        type: MasterFieldType.select,
        options: [
          MasterSelectOption(value: 'true', label: '使用（参与核算）'),
          MasterSelectOption(value: 'false', label: '不使用（不核算）'),
        ]),
    MasterFieldDef(
        key: 'status', label: '状态', group: '基础', hint: '使用 / 禁用'),
  ];

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增仓库',
      fields: _fields,
      initialValues: const {'accountable': 'true'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    try {
      await ref.read(warehouseRepositoryProvider).create(body);
      if (!mounted) return false;
      context.appSuccess('仓库已创建');
      await _loadWarehouses(_pageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('创建失败，请稍后重试');
      return false;
    }
  }

  void _showEdit(WarehouseDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑仓库',
      fields: _fields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'location': d.location ?? '',
        'accountable': d.accountable ? 'true' : 'false',
        'status': d.status ?? '',
      },
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    try {
      await ref.read(warehouseRepositoryProvider).update(id, body);
      if (!mounted) return false;
      context.appSuccess('仓库已更新');
      await _loadWarehouses(_pageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('更新失败，请稍后重试');
      return false;
    }
  }

  Future<void> _delete(WarehouseDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除仓库'),
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该仓库')}」吗？',
        ),
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
    try {
      await ref.read(warehouseRepositoryProvider).delete(d.id);
      if (!mounted) return;
      context.appSuccess('仓库已删除');
      await _loadWarehouses(_pageNum);
      if (mounted &&
          _page != null &&
          _page!.items.isEmpty &&
          _page!.page > 1) {
        await _loadWarehouses(_page!.page - 1);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试');
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
    WarehouseDetail? d;
    try {
      d = await ref.read(warehouseRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载仓库详情失败');
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
          : (detail.code ?? '仓库详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(WarehouseDetail w) => [
        MasterDetailRow('编号', w.code),
        MasterDetailRow('仓库名称', w.name),
        MasterDetailRow('位置', w.location),
        MasterDetailRow('是否核算', w.accountable ? '是' : '否'),
        MasterDetailRow('备注', w.remark),
        MasterDetailRow('状态', w.status),
        MasterDetailRow('旧车间ID', w.workshopLegacyId?.toString()),
        MasterDetailRow('旧编码', w.legacyId?.toString()),
      ];

  static final _columns = <MasterColumnDef<WarehouseListItem>>[
    MasterColumnDef(
        key: 'code', label: '编号', width: 120, value: (w) => w.code),
    MasterColumnDef(
        key: 'name', label: '仓库名称', width: 200, value: (w) => w.name),
    MasterColumnDef(
        key: 'location', label: '位置', width: 160, value: (w) => w.location),
    MasterColumnDef(
        key: 'accountable',
        label: '核算',
        width: 90,
        value: (w) => w.accountable ? '是' : '否'),
    MasterColumnDef(
        key: 'status', label: '状态', width: 100, value: (w) => w.status),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadWarehouses(1), _loadFacets()]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库资料',
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
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.warehouse_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '仓库 ($total)',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索仓库（名称/编号）',
                          initialValue: _keyword,
                          onChanged: _onKeywordChanged,
                        ),
                      ),
                      if (_canEdit) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: _showCreate,
                          child: const Text('添加仓库'),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<WarehouseListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    onRowTap: (w) => _showDetail(w.id),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadWarehouses(_pageNum),
                    emptyMessage: '暂无仓库',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _loadWarehouses(p),
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
