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
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
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

  Map<String, String?> _filters = {};
  String _keyword = '';
  ColorFacets? _facets;

  /// 详情弹窗加载中（防并发）。与 [_loading]（分页列表加载）是两回事。
  bool _detailLoading = false;

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
    if (_loading) return; // 防连点
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref.read(colorRepositoryProvider).list(
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
    } on ApiException catch (e) {
      debugPrint('color facets load failed: ${e.message}');
    } catch (_) {
      debugPrint('color facets load failed');
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
    MasterFieldDef(
        key: 'name', label: '颜色名称', required: true, group: '基础'),
    MasterFieldDef(key: 'code', label: '颜色编号', group: '基础'),
    MasterFieldDef(
        key: 'status', label: '状态', group: '基础', hint: '使用 / 禁用'),
  ];

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增颜色', // TODO(l10n): 补 arb
      fields: _colorFields,
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    try {
      await ref.read(colorRepositoryProvider).create(body);
      if (!mounted) return false;
      context.appSuccess('颜色已创建'); // TODO(l10n): 补 arb
      await _loadColors(_pageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('创建失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
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
    try {
      await ref.read(colorRepositoryProvider).update(id, body);
      if (!mounted) return false;
      context.appSuccess('颜色已更新'); // TODO(l10n): 补 arb
      await _loadColors(_pageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('更新失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
  }

  Future<void> _delete(ColorDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除颜色'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该颜色')}」吗？', // TODO(l10n): 补 arb
        ),
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
    try {
      await ref.read(colorRepositoryProvider).delete(d.id);
      if (!mounted) return;
      context.appSuccess('颜色已删除'); // TODO(l10n): 补 arb
      await _loadColors(_pageNum);
      // 删空当前页时回退上一页，避免列表空白
      if (mounted &&
          _page != null &&
          _page!.items.isEmpty &&
          _page!.page > 1) {
        await _loadColors(_page!.page - 1);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
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
        MasterDetailRow('旧编码', c.legacyId?.toString()), // TODO(l10n): 补 arb
      ];

  // ---- 列定义 -----------------------------------------------------------

  static final _columns = <MasterColumnDef<ColorListItem>>[
    MasterColumnDef(
        key: 'code', label: '编号', width: 120, value: (c) => c.code),
    MasterColumnDef(
        key: 'name', label: '颜色名称', width: 220, value: (c) => c.name),
    MasterColumnDef(
        key: 'status', label: '状态', width: 100, value: (c) => c.status),
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
          onPressed: () => context.go(RouteName.basicinfo),
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
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4, right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.palette_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '颜色 ($total)', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
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
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
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
