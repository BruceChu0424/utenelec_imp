// 颜色资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与货品/模具/客户/供应商同级，但颜色是扁平字典（编号/名称/状态 3 字段），
// 故无左树 + 右详情布局，直接：AppBar + 区段标题（含添加）+ 全屏主档表格。
// 复用 MasterDataTableView（搜索/autofilter/分页）+ showMasterEditDialog +
// showMasterDetailSheet，CRUD/详情/并发防护流程与货品 _DetailPane 一致。
// 查看全员可见（路由不设守卫），编辑按 color:edit 权限显隐。
// 文档：见 docs/03-页面/基础资料页.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/color_node.dart';
import '../repositories/color_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class ColorPage extends ConsumerStatefulWidget {
  const ColorPage({super.key});

  @override
  ConsumerState<ColorPage> createState() => _ColorPageState();
}

class _ColorPageState extends ConsumerState<ColorPage> {
  PagedResult<ColorListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  ColorFacets? _facets;

  /// 详情弹窗加载中（防并发）。与 [_loading]（分页列表加载）是两回事。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。
  Set<String> _selectedColorIds = {};

  /// 行操作进行中（启停/删除等）防并发。
  bool _rowOpBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadColors(1);
      _loadFacets();
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.colorEdit);

  // ---- 分页 -------------------------------------------------------------

  Future<void> _loadColors(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref
          .read(colorRepositoryProvider)
          .list(
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
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
        _error = '加载颜色列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(colorRepositoryProvider).facets();
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
    _loadColors(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadColors(1);
  }

  // ---- 新建/编辑/删除 ---------------------------------------------------

  static const _colorFields = [
    MasterFieldDef(key: 'name', label: '颜色名称', required: true, group: '基础'),
    MasterFieldDef(key: 'code', label: '颜色编号', group: '基础', hint: '留空自动生成'),
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
      title: '新增颜色', // TODO(l10n): 补 arb
      fields: _colorFields,
      initialValues: const {'status': '使用'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () => ref.read(colorRepositoryProvider).create(body),
      success: '颜色已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadColors(_pageNum);
    return true;
  }

  void _showEdit(ColorDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑颜色', // TODO(l10n): 补 arb
      fields: _colorFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'status': d.status ?? '',
      },
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () => ref.read(colorRepositoryProvider).update(id, body),
      success: '颜色已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadColors(_pageNum);
    return true;
  }

  Future<void> _delete(ColorDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除颜色'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该颜色')}」吗？', // TODO(l10n): 补 arb
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final deleted = await context.guardRun(
      () => ref.read(colorRepositoryProvider).delete(d.id),
      success: '颜色已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadColors(_pageNum);
    // 删空当前页时回退上一页，避免列表空白
    if (mounted && _page != null && _page!.items.isEmpty && _page!.page > 1) {
      await _loadColors(_page!.page - 1);
    }
  }

  /// 点行：拉详情弹框。独立 [_detailLoading] 防并发 + rootNavigator 防 go_router 误 pop。
  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    ColorDetail? d;
    try {
      d = await ref.read(colorRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载颜色详情失败'); // TODO(l10n): 补 arb
    }
    if (!mounted) {
      nav.pop();
      return;
    }
    nav.pop(); // 关 loading
    if (d == null) {
      _detailLoading = false;
      return;
    }
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '颜色详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(ColorDetail c) => [
    MasterDetailRow('编号', c.code), // TODO(l10n): 补 arb
    MasterDetailRow('颜色名称', c.name), // TODO(l10n): 补 arb
    MasterDetailRow('状态', c.status), // TODO(l10n): 补 arb
    MasterDetailRow('旧系统 ID', c.legacyId?.toString()), // TODO(l10n): 补 arb
  ];

  // ---- 行菜单（右击/长按）+ 多选批量 --------------------------------------

  /// 启用/禁用颜色：直接以列表行字段全量回传、仅改状态（颜色只有 编号/名称/状态 3 字段）。
  Future<void> _toggleColorStatus(ColorListItem c) async {
    if (_rowOpBusy) return;
    final next = c.status == '使用' ? '禁用' : '使用';
    _rowOpBusy = true;
    final ok = await context.guardRun(
      () => ref.read(colorRepositoryProvider).update(c.id, {
        'name': c.name ?? '',
        'code': c.code,
        'status': next,
      }),
      success: next == '禁用' ? '颜色已禁用' : '颜色已启用', // TODO(l10n): 补 arb
    );
    if (ok && mounted) await _loadColors(_pageNum);
    _rowOpBusy = false;
  }

  /// 菜单「编辑/删除」：先拉详情再走既有流程。
  Future<void> _withColorDetail(
    String id,
    Future<void> Function(ColorDetail d) action,
  ) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    ColorDetail? d;
    try {
      d = await ref.read(colorRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载颜色详情失败'); // TODO(l10n): 补 arb
    }
    _rowOpBusy = false;
    if (d != null && mounted) await action(d);
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限 + 行状态实时决定。
  List<UtenContextMenuEntry> _colorMenuItems(ColorListItem c) {
    final inUse = c.status == '使用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showDetail(c.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: inUse ? '禁用颜色' : '启用颜色',
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _canEdit,
        destructive: inUse,
        onTap: () => _toggleColorStatus(c),
      ),
      UtenMenuItem(
        label: '编辑颜色',
        icon: Icons.edit_outlined,
        enabled: _canEdit,
        onTap: () => _withColorDetail(c.id, (d) async => _showEdit(d)),
      ),
      UtenMenuItem(
        label: '删除颜色',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canEdit,
        onTap: () => _withColorDetail(c.id, _delete),
      ),
    ];
  }

  List<Widget> _colorBatchActions(BuildContext context, Set<String> ids) {
    if (!_canEdit) return const [];
    return [
      UtenButton(
        size: UtenButtonSize.small,
        type: UtenButtonType.tonal,
        icon: Icons.pause_circle_outline_rounded,
        onPressed: _rowOpBusy ? null : () => _batchSetColorStatus(ids, '禁用'),
        child: const Text('批量禁用'), // TODO(l10n): 补 arb
      ),
      UtenButton(
        size: UtenButtonSize.small,
        type: UtenButtonType.danger,
        icon: Icons.delete_outline_rounded,
        onPressed: _rowOpBusy ? null : () => _batchDeleteColors(ids),
        child: const Text('批量删除'), // TODO(l10n): 补 arb
      ),
    ];
  }

  /// 批量启停：逐条回传更新（无专用批量接口）；跳过已是目标状态的行。
  Future<void> _batchSetColorStatus(Set<String> ids, String status) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final repo = ref.read(colorRepositoryProvider);
    final byId = {
      for (final c in _page?.items ?? const <ColorListItem>[]) c.id: c,
    };
    var okCount = 0;
    var skipped = 0;
    for (final id in ids) {
      final c = byId[id];
      try {
        if (c != null && c.status == status) {
          skipped++;
          continue;
        }
        // 选中行可能不在当前页（跨页选择）：以详情为准取 name/code。
        final d = c == null ? await repo.detail(id) : null;
        await repo.update(id, {
          'name': c?.name ?? d?.name ?? '',
          'code': c?.code ?? d?.code,
          'status': status,
        });
        okCount++;
      } catch (_) {
        skipped++;
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedColorIds = {});
    context.appSuccess(
      status == '禁用'
          ? '已禁用 $okCount 个颜色${skipped > 0 ? '，$skipped 个跳过' : ''}'
          : '已启用 $okCount 个颜色${skipped > 0 ? '，$skipped 个跳过' : ''}',
    );
    await _loadColors(_pageNum);
  }

  /// 批量删除：确认后逐个删（容忍单条失败，如被货品引用）。
  Future<void> _batchDeleteColors(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除颜色'), // TODO(l10n): 补 arb
        content: Text('确定删除选中的 ${ids.length} 个颜色吗？被货品引用的颜色会删除失败。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _rowOpBusy = true;
    final repo = ref.read(colorRepositoryProvider);
    var okCount = 0;
    final failed = <String>{};
    for (final id in ids) {
      try {
        await repo.delete(id);
        okCount++;
      } on ApiException catch (e) {
        failed.add(e.message);
      } catch (_) {
        failed.add('删除失败');
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedColorIds = {});
    context.appSuccess(
      '已删除 $okCount 个颜色${failed.isNotEmpty ? '，${ids.length - okCount} 个失败' : ''}',
    );
    if (failed.isNotEmpty) context.appError(failed.first);
    await _loadColors(_pageNum);
  }

  // ---- 列定义 -----------------------------------------------------------

  static final _columns = <MasterColumnDef<ColorListItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (c) => c.code),
    MasterColumnDef(
      key: 'name',
      label: '颜色名称',
      width: 220,
      value: (c) => c.name,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (c) => c.status,
    ),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadColors(1), _loadFacets()]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '颜色资料', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
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
                        Icons.palette_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '颜色 ($total)', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索颜色（名称/编号）', // TODO(l10n): 补 arb
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
                          child: const Text('添加颜色'), // TODO(l10n): 补 arb
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<ColorListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                    selectable: true,
                    idOf: (c) => c.id,
                    selectedIds: _selectedColorIds,
                    onSelectedIdsChanged: (s) =>
                        setState(() => _selectedColorIds = s),
                    batchActionsBuilder: _colorBatchActions,
                    // 行菜单（右击/长按）：查看/启用/禁用/编辑/删除。
                    rowMenuBuilder: _colorMenuItems,
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    // 行底色按状态：使用=浅蓝、禁用=浅红；单击选中自动加深加亮。
                    rowColor: (c) => switch (c.status) {
                      '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                      '禁用' => Colors.red.withValues(alpha: 0.10),
                      _ => null,
                    },
                    onRowTap: (c) => _showDetail(c.id),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadColors(_pageNum),
                    emptyMessage: '暂无颜色', // TODO(l10n): 补 arb
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _loadColors(p),
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
