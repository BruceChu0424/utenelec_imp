// 货品资料分类树管理页（基础资料）
//
// 拷贝自部门管理页（department_page.dart）改造：
// - 详情面板只调 productCategoryRepository.detail（不拉员工）；
// - 编辑类按钮（新增/编辑/删除）按 material_category:edit 权限显隐；
//   查看全员可见（路由不设守卫）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/03-页面/ 总览（基础资料）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/goods_bom_item.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../providers/goods_clipboard.dart';
import '../repositories/goods_bom_repository.dart';
import '../repositories/goods_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/product_category_repository.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/goods_import_dialog.dart';
import '../models/goods_import.dart';
import '../repositories/goods_import_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/system_master_category_guard.dart';

class ProductCategoryPage extends ConsumerStatefulWidget {
  const ProductCategoryPage({super.key});

  @override
  ConsumerState<ProductCategoryPage> createState() =>
      _ProductCategoryPageState();
}

class _ProductCategoryPageState extends ConsumerState<ProductCategoryPage>
    with CategoryPageShell<ProductCategoryPage> {
  int _detailEpoch = 0;

  /// 导入/撤回后：刷新分类树 + 重挂详情面板（强刷货品列表）。
  void _reloadAll() {
    shellReload();
    setState(() => _detailEpoch++);
  }

  Future<void> _undoLatestImport() async {
    GoodsImportBatchInfo? batch;
    try {
      batch = await ref.read(goodsImportRepositoryProvider).latest();
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e);
      return;
    }
    if (!mounted) return;
    if (batch == null) {
      context.appError('没有可撤回的导入');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回最近一次导入'),
        content: Text(
          '将撤销最近一次导入的 ${batch!.rowCount} 条货品'
          '${(batch.filename != null && batch.filename!.isNotEmpty) ? "(${batch.filename})" : ""}'
          '，及本次新建的分类/颜色/单位。确认撤回？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(goodsImportRepositoryProvider).undo(batch.id);
      if (!mounted) return;
      context.appSuccess('已撤回最近一次导入');
      _reloadAll();
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  // ---- 壳层钩子（货品页差异：树常驻 / 未分类折叠 / 撤回导入 / 分批搜索 / 级联删除）----

  @override
  String get shellTitle => '货品资料'; // TODO(l10n): 补 arb

  @override
  String get shellSearchHint => '搜索分类/货品名称或编号'; // TODO(l10n): 补 arb

  @override
  String get shellContentNoun => '货品';

  @override
  IconData get shellEmptyIcon => Icons.category_outlined;

  @override
  String get shellPersistenceKey => 'basicData.goods';

  @override
  bool get shellCanCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.materialCategoryCreate);

  @override
  bool get shellCanEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.materialCategoryEdit);

  @override
  bool get shellCanDelete => ref
      .read(currentPermissionsProvider)
      .contains(Perm.materialCategoryDelete);

  @override
  bool get shellCanMove =>
      ref.read(currentPermissionsProvider).contains(Perm.materialCategoryMove);

  @override
  bool get shellCanReorder => ref
      .read(currentPermissionsProvider)
      .contains(Perm.materialCategoryReorder);

  /// 已有分类树时保持挂载（不切全屏 spinner），保住树的展开状态。
  @override
  bool get shellKeepTreeMounted => true;

  @override
  bool get shellInitiallyCollapseUncategorized => true;

  @override
  List<Widget> shellExtraAppBarActions(
    BuildContext context, {
    required bool compact,
    required bool treeNotEmpty,
  }) {
    if (!ref.read(currentPermissionsProvider).contains(Perm.goodsImportUndo)) {
      return const [];
    }
    return [
      IconButton(
        icon: const Icon(Icons.undo_rounded),
        tooltip: '撤回导入', // TODO(l10n): 补 arb
        onPressed: _undoLatestImport,
      ),
    ];
  }

  @override
  Future<List<ProductCategoryNode>> shellLoadTree() =>
      ref.read(productCategoryRepositoryProvider).tree();

  @override
  Future<void> shellCreateCategory(CategoryEditResult r) => ref
      .read(productCategoryRepositoryProvider)
      .create(
        ProductCategorySaveInput(
          name: r.name,
          remark: r.remark,
          codePrefix: r.codePrefix,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
        ),
      );

  @override
  Future<void> shellUpdateCategory(String id, CategoryEditResult r) => ref
      .read(productCategoryRepositoryProvider)
      .update(
        id,
        ProductCategoryUpdateInput(
          name: r.name,
          codePrefix: r.codePrefix,
          remark: r.remark,
          version: r.version ?? 0,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
          moveToRoot: r.moveToRoot,
        ),
      );

  @override
  Future<void> shellDeleteCategory(String id) =>
      ref.read(productCategoryRepositoryProvider).delete(id);

  @override
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  ) => ref
      .read(productCategoryRepositoryProvider)
      .prefixPreview(id, prefix, parentId: parentId);

  /// 用轻量定位端点取全部命中分类，不拉取/遍历完整货品分页。
  @override
  Future<Set<String>?> shellContentCategoryIds(
    String q,
    bool Function() isCurrent,
  ) async {
    final repo = ref.read(goodsRepositoryProvider);
    final roots = (shellTree ?? const <ProductCategoryNode>[])
        .map((node) => node.id)
        .toList(growable: false);
    final categoryIds = <String>{};
    // 后端每次最多接收 32 个根；动态分类超过上限时分批并集，仍保持 fail-closed。
    for (var offset = 0; offset < roots.length; offset += 32) {
      final end = offset + 32 < roots.length ? offset + 32 : roots.length;
      categoryIds.addAll(
        await repo.searchCategoryIds(
          q,
          categoryRootIds: roots.sublist(offset, end).toSet(),
          excludeStub: true,
        ),
      );
      if (!isCurrent()) return null;
    }
    if (!isCurrent()) return null;
    return categoryIds;
  }

  /// 级联删除：先拉子树规模预览（后代分类数 + 货品数）红框确认；
  /// 失败弹 AlertDialog 显示后端原因（不再静默/仅顶部 toast），成功给计数文案。
  @override
  Future<void> shellDeleteNode(ProductCategoryNode node) async {
    if (isSystemUncategorizedCategory(systemManaged: node.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    ProductCategoryDeletePreview? preview;
    try {
      preview = await ref
          .read(productCategoryRepositoryProvider)
          .deletePreview(node.id);
    } catch (_) {
      preview = null; // 预览失败不阻塞：退回无计数的通用确认。
    }
    if (!mounted) return;

    final hasCascade =
        preview != null &&
        (preview.descendantCount > 0 || preview.goodsCount > 0);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: UtenColors.error),
            SizedBox(width: UtenSpacing.s8),
            Text('删除分类'), // TODO(l10n): 补 arb
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除分类「${node.name}」吗？'), // TODO(l10n): 补 arb
            if (hasCascade) ...[
              const SizedBox(height: UtenSpacing.s12),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: UtenColors.error.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: UtenColors.error.withValues(alpha: 0.45),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview!.descendantCount > 0)
                      Text(
                        '• ${preview.descendantCount} 个子分类',
                      ), // TODO(l10n): 补 arb
                    if (preview.goodsCount > 0)
                      Text('• ${preview.goodsCount} 个货品'), // TODO(l10n): 补 arb
                    const SizedBox(height: UtenSpacing.s4),
                    const Text(
                      '以上将随该分类一并删除，且不可恢复。', // TODO(l10n): 补 arb
                      style: TextStyle(color: UtenColors.error),
                    ),
                  ],
                ),
              ),
            ],
          ],
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
    if (confirm != true) return;
    if (!mounted) return;

    try {
      await shellDeleteCategory(node.id);
    } on ApiException catch (e) {
      if (mounted) {
        await _showDeleteError(
          e.message.isNotEmpty ? e.message : '删除失败，请稍后重试', // TODO(l10n): 补 arb
        );
      }
      return;
    } catch (_) {
      if (mounted) {
        await _showDeleteError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
      }
      return;
    }
    if (!mounted) return;
    shellAfterCategoryDeleted(node.id);
    final msg =
        (preview != null &&
            (preview.descendantCount > 0 || preview.goodsCount > 0))
        ? '已删除分类(含 ${preview.descendantCount} 个子分类、${preview.goodsCount} 个货品)'
        : '分类已删除';
    if (mounted) context.appSuccess(msg); // TODO(l10n): 补 arb
    await shellReload();
  }

  /// 删除失败的错误对话框（显式弹窗，而非顶部 toast），展示后端返回的原因。
  Future<void> _showDeleteError(String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline_rounded, color: UtenColors.error),
            SizedBox(width: UtenSpacing.s8),
            Text('删除失败'), // TODO(l10n): 补 arb
          ],
        ),
        content: Text(message),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => shellReload());
  }

  /// 分类创建/编辑保存后：除了树（shellReload 已做），还要重挂右栏详情面板——
  /// 否则分类卡片仍显示旧名称/前缀，需要手动刷新才能看到最新值。
  @override
  void shellAfterCategorySaved() => setState(() => _detailEpoch++);

  @override
  Widget build(BuildContext context) {
    return buildShell(
      context,
      detailPaneBuilder: (selected) => _DetailPane(
        key: ValueKey('dp-${selected.id}-$_detailEpoch'),
        ref: ref,
        nodeId: selected.id,
        canEdit: shellCanEdit,
        canAddCategory: shellCanCreate,
        canDeleteCategory: shellCanDelete,
        externalKeyword: shellTreeSearchKeyword,
        onAddChild: () => shellShowCreateDialog(parent: selected),
        onEdit: (detail) => shellShowEditDialog(detail),
        onDelete: () => shellDeleteNode(selected),
        onDataChanged: shellReload,
      ),
    );
  }
}

/// 分类详情面板：只调 detail（不拉员工/岗位）。
class _DetailPane extends StatefulWidget {
  const _DetailPane({
    super.key,
    required this.ref,
    required this.nodeId,
    required this.canEdit,
    required this.canAddCategory,
    required this.canDeleteCategory,
    required this.externalKeyword,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
    required this.onDataChanged,
  });

  final WidgetRef ref;
  final String nodeId;
  final bool canEdit;
  final bool canAddCategory;
  final bool canDeleteCategory;

  /// 顶部树搜索命中货品时传入的过滤词：详情面板把它采纳为本地面货品列表的搜索词，
  /// 使右侧只显示本次搜索结果；为 null 时不过滤（显示该分类全部）。
  final String? externalKeyword;
  final VoidCallback onAddChild;
  final void Function(ProductCategoryDetail detail) onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDataChanged;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  final _detailRequests = LatestRequestGuard();
  final _goodsRequests = LatestRequestGuard();
  final _specialCollectionRequests = LatestRequestGuard();
  ProductCategoryDetail? _detail;
  bool _loading = true;
  String? _error;

  // 该分类（子树）下的货品分页；父分类也加载（子树汇总）。
  PagedResult<GoodsListItem>? _goodsPage;
  int _goodsPageNum = 1;
  bool _goodsLoading = false;
  String? _goodsError;

  // 特殊货品集合（表头下前导分组）：禁用货品（当前分类子树）/ 不明货品（仅未分类节点）。
  // 主表已 excludeDisabled+excludeStub，二者不重复；这里作为可折叠分组渲染于表头下第一区。
  PagedResult<GoodsListItem>? _disabledGoods;
  PagedResult<GoodsListItem>? _stubGoods;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  GoodsFacets? _facets;

  // 搜索框重建种子：外部关键词（树搜索）变化时自增，驱动 UtenSearchBar 用新 initialValue 重建。
  int _kwSeed = 0;

  // 列排序态：默认按编号(code)升序；用户点「取消排序」清空后 null = 后端默认 id ASC。
  String? _sortKey = 'code';
  bool _sortAsc = true;

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_goodsLoading]（货品分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_goodsLoading] 恒为 false，无法防止详情弹窗被并发触发。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。切换分类时清空。
  Set<String> _selectedGoodsIds = {};

  /// 行操作进行中（复制/粘贴/启停/组件信息操作）防并发。
  bool _rowOpBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DetailPane old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) {
      _load();
      return;
    }
    // 同一分类下外部搜索词变化（树搜索命中/解除）：采纳为本地关键词并重查第 1 页。
    if (old.externalKeyword != widget.externalKeyword) {
      setState(() {
        _kwSeed++;
        _keyword = widget.externalKeyword ?? '';
      });
      Future.wait([_loadGoods(1), _loadSpecialCollections()]);
    }
  }

  Future<void> _load() async {
    final generation = _detailRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.ref
          .read(productCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置货品分页 + 筛选状态 + facet + 排序态 + 特殊集合。
        _goodsPage = null;
        _goodsPageNum = 1;
        _goodsError = null;
        _filters = {};
        // 外部搜索词（树搜索命中）随分类切换一并带入：搜索定位时右侧只显示搜索结果。
        _keyword = widget.externalKeyword ?? '';
        _kwSeed++;
        _facets = null;
        _sortKey = 'code';
        _sortAsc = true;
        _disabledGoods = null;
        _stubGoods = null;
        _selectedGoodsIds = {}; // 切分类清空多选（选中的是旧分类的行）
      });
      // 父分类也加载（后端按子树汇总）；并行拉货品列表、字段 facet 与特殊集合。
      await Future.wait([
        _loadGoods(1),
        _loadFacets(),
        _loadSpecialCollections(),
      ]);
    } on ApiException catch (e) {
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载分类详情失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 货品分页 ----------------------------------------------------------

  Future<void> _loadGoods(int page) async {
    final generation = _goodsRequests.begin();
    setState(() {
      _goodsLoading = true;
      _goodsError = null;
      _goodsPageNum = page;
    });
    try {
      final result = await widget.ref
          .read(goodsRepositoryProvider)
          .list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
            // 浏览态沿用特殊集合；搜索态把禁用品直接纳入结果，避免“定位到了但右侧为空”。
            excludeDisabled: _keyword.trim().isEmpty,
            excludeStub: true, // stub(迁移兜底)归「未分类」节点集合行
          );
      if (!mounted || !_goodsRequests.isCurrent(generation)) return;
      setState(() {
        _goodsPage = result;
      });
    } on ApiException catch (e) {
      if (!mounted || !_goodsRequests.isCurrent(generation)) return;
      setState(() {
        _goodsError = e.message;
      });
    } catch (_) {
      if (!mounted || !_goodsRequests.isCurrent(generation)) return;
      setState(() {
        _goodsError = '加载货品列表失败'; // TODO(l10n): 补 arb
      });
    } finally {
      if (mounted && _goodsRequests.isCurrent(generation)) {
        setState(() => _goodsLoading = false);
      }
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f = await widget.ref
          .read(goodsRepositoryProvider)
          .facets(widget.nodeId);
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  /// 加载特殊货品集合（表头下前导分组）：禁用货品（当前分类子树 status='禁用'）/
  /// 不明货品（仅未分类节点，stub 无分类 → 查询不带 categoryId）。失败静默（辅助视图）。
  Future<void> _loadSpecialCollections() async {
    final generation = _specialCollectionRequests.begin();
    if (_keyword.trim().isNotEmpty) {
      setState(() {
        _disabledGoods = null;
        _stubGoods = null;
      });
      return;
    }
    final repo = widget.ref.read(goodsRepositoryProvider);
    final isOrphan = _detail?.systemManaged ?? false;
    try {
      final results = await Future.wait<PagedResult<GoodsListItem>?>([
        repo.list(widget.nodeId, disabledOnly: true, size: 500),
        isOrphan
            ? repo.list(null, stubOnly: true, size: 500)
            : Future<PagedResult<GoodsListItem>?>.value(),
      ]);
      if (!mounted || !_specialCollectionRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _disabledGoods = results[0];
        _stubGoods = results[1];
      });
    } catch (_) {
      // 集合区是辅助视图，失败静默（不影响主表）。
    }
  }

  /// 构建表头下前导分组（禁用货品 / 不明货品）。N=0 的不加入。
  List<MasterDataGroup<GoodsListItem>> get _leadingGroups {
    final groups = <MasterDataGroup<GoodsListItem>>[];
    final d = _disabledGoods;
    if (d != null && d.total > 0) {
      groups.add(
        MasterDataGroup<GoodsListItem>(
          id: 'disabled',
          title: '禁用货品(${d.total})',
          subtitle: '当前分类子树内已停用的货品',
          icon: Icons.block_rounded,
          tint: Colors.red.withValues(alpha: 0.12),
          items: d.items,
          total: d.total,
        ),
      );
    }
    if (_detail?.systemManaged ?? false) {
      final s = _stubGoods;
      if (s != null && s.total > 0) {
        groups.add(
          MasterDataGroup<GoodsListItem>(
            id: 'stub',
            title: '不明货品(${s.total})',
            subtitle: '迁移兜底占位(auto_created)，无分类归属',
            icon: Icons.help_outline_rounded,
            tint: Colors.amber.withValues(alpha: 0.16),
            items: s.items,
            total: s.total,
          ),
        );
      }
    }
    return groups;
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key); // 选"所有"= 不筛
      } else {
        next[key] = value; // 具体值 或 kMasterFilterNullValue（空值）
      }
      _filters = next;
    });
    _loadGoods(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadGoods(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadGoods(1); // 排序变化回第 1 页重载
  }

  /// 导出查询参数（与 _loadGoods 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'categoryId': widget.nodeId,
    'excludeDisabled': true,
    'excludeStub': true,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前分类/筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await widget.ref
        .read(goodsRepositoryProvider)
        .list(
          widget.nodeId,
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          excludeDisabled: true,
          excludeStub: true,
        );
    return UtenPrintTable(
      headers: [for (final c in _visibleGoodsColumns) c.label],
      rows: [
        for (final a in result.items)
          [for (final c in _visibleGoodsColumns) c.value(a) ?? ''],
      ],
    );
  }

  bool get _canCreateMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsCreate);
  bool get _canDeleteMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsDelete);
  bool get _canStatusMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsStatus);
  bool get _canBomCreate =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsBomCreate);
  bool get _canBomEdit =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsBomEdit);
  bool get _canBomDelete =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsBomDelete);
  bool get _canReplaceBom => _canBomCreate && _canBomEdit && _canBomDelete;

  /// 无 goods:discount:view 权限者：列表折扣列整列移除（表头设置也不再列出，符合权限语义）。
  bool get _canViewDiscount => widget.ref
      .read(currentPermissionsProvider)
      .contains(Perm.goodsDiscountView);

  List<MasterColumnDef<GoodsListItem>> get _visibleGoodsColumns =>
      _canViewDiscount
      ? _goodsColumns
      : [
          for (final c in _goodsColumns)
            if (c.key != 'discount') c,
        ];

  // ---- 行菜单（右击/长按）：复制/粘贴/启停/删除 + 组件信息 ----------------

  bool get _canEditPrice =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsPriceEdit);

  String _goodsLabel(GoodsListItem g) =>
      g.name?.isNotEmpty == true ? g.name! : (g.code ?? '该货品');

  /// 粘贴生成的新货品名称：尾部加「(n)」副本标记，与原货品区分。
  /// 源名已带副本标记时顺延为 n+1（X→X(1)、X(1)→X(2)），避免无限叠加；
  /// 括号匹配全角「（）」与半角「()」两种（历史数据里存在全角副本名）。
  /// 并避开 [taken]（当前列表已加载的货品名 + 同批已生成的名字），同批多份依次顺延。
  String _pastedGoodsName(String? raw, Set<String> taken) {
    final n = (raw ?? '').trim();
    if (n.isEmpty) return n;
    final m = RegExp('^(.*)[（(](\\d+)[）)]\$').firstMatch(n);
    final base = m?.group(1) ?? n;
    var seq = m != null ? int.parse(m.group(2)!) + 1 : 1;
    var candidate = '$base($seq)';
    while (taken.contains(candidate)) {
      seq++;
      candidate = '$base($seq)';
    }
    return candidate;
  }

  /// 当前分类列表已加载的货品名集合（粘贴命名避让用；分页外未加载的靠顺延大概率避开）。
  Set<String> _loadedGoodsNames() => {
    for (final g in _goodsPage?.items ?? const <GoodsListItem>[])
      if ((g.name ?? '').trim().isNotEmpty) g.name!.trim(),
  };

  /// 详情 → 保存请求体（启停/复制共用；字段与后端 GoodsSaveRequest 对齐）。
  /// [copyMode]=true 时不带编号（留空后端自动生成），且无 goods:price:edit 权限时
  /// 不带价格/折扣（后端对「新建带价」按触碰处理，会 403）；编辑场景原值回传，
  /// 值未变不触发 price:edit 校验，折扣脱敏（null）也不会误清。
  Map<String, dynamic> _goodsSaveBody(
    GoodsDetail d, {
    String? categoryId,
    String? status,
    bool copyMode = false,
  }) {
    final body = <String, dynamic>{
      'categoryId': resolveGoodsSaveCategoryId(
        currentCategoryId: widget.nodeId,
        sourceCategoryId: d.categoryId,
        requestedCategoryId: categoryId,
        copyMode: copyMode,
      ),
      'name': d.name ?? '',
      'status': status ?? d.status ?? '使用',
      'shortName': d.shortName,
      'sourceType': d.sourceType,
      'model': d.model,
      'spec': d.spec,
      'material': d.material,
      'series': d.series,
      'stockPlace': d.stockPlace,
      'thickness': d.thickness,
      'mWeight': d.mWeight,
      ...goodsUuidFirstReferenceBody(d),
      'pack': d.pack,
      'pieces': d.pieces,
      // 成本字段全量回传（后端 apply 全量覆盖语义，缺字段会被清 null）。
      'sourceE': d.sourceE,
      'machiningE': d.machiningE,
      'incidentalE': d.incidentalE,
      'lacquerE': d.lacquerE,
      'platingE': d.platingE,
      'casingE': d.casingE,
      'polishE': d.polishE,
      'total': d.total,
      'workRate': d.workRate,
      'workE': d.workE,
      'lostRate': d.lostRate,
      'lostE': d.lostE,
      'rentRate': d.rentRate,
      'rentE': d.rentE,
      'makeRate': d.makeRate,
      'makeE': d.makeE,
      'cTotal': d.cTotal,
      'gTotal': d.gTotal,
    };
    if (!copyMode) {
      body['code'] = d.code;
      if (d.version != null) body['version'] = d.version;
    }
    if (!copyMode || _canEditPrice) {
      body['price'] = d.price;
      body['discount'] = d.discount;
    }
    return normalizeGoodsUuidFirstBody(body);
  }

  /// BOM 行 → 新建请求体（粘贴组件信息用；字段与后端 BomItemSaveRequest 对齐）。
  Map<String, dynamic> _bomSaveBody(GoodsBomItem it) => <String, dynamic>{
    'componentGoodsId': it.componentGoodsId,
    'qty': it.qty ?? 1,
    'price': it.price,
    'total': it.total,
    'summary': it.summary,
    'controlStage': it.controlStage.code,
    'consumptionBasis': it.consumptionBasis.code,
    'basisOutputQty': it.basisOutputQty,
    'allowPartialPackage': it.allowPartialPackage,
    'hardGate': it.hardGate,
    if (it.colorId != null) 'colorId': it.colorId,
    if (it.defaultSupplierId != null) 'defaultSupplierId': it.defaultSupplierId,
  };

  /// 拉货品详情（行操作共用）；失败已 toast，返回 null。
  Future<GoodsDetail?> _fetchGoodsDetail(String id) async {
    try {
      return await widget.ref.read(goodsRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载货品详情失败'); // TODO(l10n): 补 arb
    }
    return null;
  }

  /// 「复制货品」：整份详情快照进 App 内剪贴板。
  Future<void> _copyGoods(GoodsListItem g) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    final d = await _fetchGoodsDetail(g.id);
    if (d != null && mounted) {
      widget.ref.read(goodsClipboardProvider.notifier).copyGoods(d);
      context.appSuccess(
        '已复制货品「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '')}」，可在目标分类下粘贴',
      );
    }
    _rowOpBusy = false;
  }

  /// 「粘贴货品」：以剪贴板快照在当前分类下新建（编号自动生成，名称加「（n）」
  /// 副本标记便于识别）。粘贴货品槽的**全部**货品各 1 份（单复制时 1 个；批量复制后多个）。
  Future<void> _pasteGoods() async {
    if (_rowOpBusy) return;
    final clips = widget.ref.read(goodsClipboardProvider).goodsList;
    if (clips.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(goodsRepositoryProvider);
    final taken = _loadedGoodsNames();
    var ok = 0;
    for (final d in clips) {
      try {
        final body = _goodsSaveBody(d, copyMode: true);
        final newName = _pastedGoodsName(d.name, taken);
        if (newName.isNotEmpty) {
          body['name'] = newName;
          taken.add(newName);
        }
        await repo.create(body);
        ok++;
      } catch (_) {}
    }
    _rowOpBusy = false;
    if (!mounted) return;
    if (ok > 0) {
      context.appSuccess('已粘贴 $ok 个新货品(编号自动生成)'); // TODO(l10n): 补 arb
      await _loadGoods(_goodsPageNum);
      await _loadSpecialCollections();
    } else {
      context.appError('粘贴失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// 「禁用/启用货品」：拉详情全量回传、仅改状态。
  Future<void> _toggleGoodsStatus(GoodsListItem g) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    final d = await _fetchGoodsDetail(g.id);
    if (d == null || !mounted) {
      _rowOpBusy = false;
      return;
    }
    final next = d.status == '禁用' ? '使用' : '禁用';
    final ok = await context.guardRun(
      () => widget.ref
          .read(masterStatusRepositoryProvider)
          .change(
            resourcePath: ApiEndpoints.good(d.id),
            status: next,
            version: d.version,
          ),
      success: next == '禁用' ? '货品已禁用' : '货品已启用', // TODO(l10n): 补 arb
    );
    if (ok && mounted) {
      // 禁用货品归前导分组行，状态变化后主表与集合行都要重拉。
      await _loadGoods(_goodsPageNum);
      await _loadSpecialCollections();
    }
    _rowOpBusy = false;
  }

  /// 菜单「删除货品」：先拉详情再走既有确认弹窗删除流程。
  Future<void> _deleteGoodsById(String id) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    final d = await _fetchGoodsDetail(id);
    _rowOpBusy = false;
    if (d != null && mounted) await _deleteGoods(d);
  }

  /// 「复制组件信息」：把该货品的 BOM 行快照进剪贴板。
  Future<void> _copyBom(GoodsListItem g) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    try {
      final items = await widget.ref
          .read(goodsBomRepositoryProvider)
          .list(g.id);
      if (!mounted) {
        _rowOpBusy = false;
        return;
      }
      if (items.isEmpty) {
        context.appError('「${_goodsLabel(g)}」没有组件信息可复制');
      } else {
        widget.ref
            .read(goodsClipboardProvider.notifier)
            .copyBom(items, _goodsLabel(g));
        context.appSuccess('已复制 ${items.length} 个组件，可在目标货品上粘贴');
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('读取组件信息失败');
    }
    _rowOpBusy = false;
  }

  /// 粘贴组件信息内核：对单个目标货品执行替换/追加粘贴，返回实际粘贴数。
  /// replace=true 先逐条删现有组件（容忍单条失败）；再逐条 create，重复/环路（409）
  /// 等后端拒绝跳过。单粘贴 [_pasteBom] 与批量 [_batchPasteBom] 共用本内核。
  Future<int> _applyPasteBom(
    String targetId,
    List<GoodsBomItem> items,
    bool replace,
  ) async {
    final repo = widget.ref.read(goodsBomRepositoryProvider);
    if (replace) {
      try {
        for (final e in await repo.list(targetId)) {
          try {
            await repo.delete(targetId, e.id);
          } catch (_) {}
        }
      } catch (_) {}
    }
    var okCount = 0;
    for (final it in items) {
      try {
        await repo.create(targetId, _bomSaveBody(it));
        okCount++;
      } catch (_) {} // 组件重复/环路（409）等后端拒绝：跳过
    }
    return okCount;
  }

  /// 「粘贴组件信息」：目标已有组件时弹窗让用户选「替换」或「同级追加」。
  Future<void> _pasteBom(GoodsListItem g) async {
    if (_rowOpBusy) return;
    final clip = widget.ref.read(goodsClipboardProvider);
    final items = clip.bomItems;
    if (items == null || items.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(goodsBomRepositoryProvider);
    List<GoodsBomItem> existing;
    try {
      existing = await repo.list(g.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
      _rowOpBusy = false;
      return;
    } catch (_) {
      if (mounted) context.appError('读取目标货品组件信息失败');
      _rowOpBusy = false;
      return;
    }
    if (!mounted) {
      _rowOpBusy = false;
      return;
    }
    final sourceLabel = clip.bomSourceLabel ?? '剪贴板';
    var replace = false;
    if (existing.isNotEmpty) {
      // 目标本来就有组件：必须让用户确认是「替换」还是「同级追加」。
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('粘贴组件信息'), // TODO(l10n): 补 arb
          content: Text(
            '「${_goodsLabel(g)}」已有 ${existing.length} 个组件。\n'
            '从「$sourceLabel」复制的 ${items.length} 个组件要如何粘贴？',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'), // TODO(l10n): 补 arb
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, 'append'),
              child: const Text('同级追加'), // TODO(l10n): 补 arb
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('替换现有组件'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      );
      if (choice == null || !mounted) {
        _rowOpBusy = false;
        return;
      }
      replace = choice == 'replace';
    } else {
      // 目标没有组件：确认来源与数量即可。
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('粘贴组件信息'), // TODO(l10n): 补 arb
          content: Text(
            '将从「$sourceLabel」复制的 ${items.length} 个组件粘贴到「${_goodsLabel(g)}」？',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'), // TODO(l10n): 补 arb
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('粘贴'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      );
      if (ok != true || !mounted) {
        _rowOpBusy = false;
        return;
      }
    }
    final okCount = await _applyPasteBom(g.id, items, replace);
    _rowOpBusy = false;
    if (!mounted) return;
    if (okCount > 0) {
      final skipped = items.length - okCount;
      context.appSuccess(
        '已粘贴 $okCount 个组件${skipped > 0 ? '，$skipped 个跳过(重复或环路)' : ''}',
      );
    } else {
      context.appError('粘贴失败：${items.length} 个组件均被跳过(重复或环路)');
    }
  }

  /// 「删除组件信息」：确认后删除该货品的全部 BOM 行。
  Future<void> _deleteBom(GoodsListItem g) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(goodsBomRepositoryProvider);
    List<GoodsBomItem> existing;
    try {
      existing = await repo.list(g.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
      _rowOpBusy = false;
      return;
    } catch (_) {
      if (mounted) context.appError('读取组件信息失败');
      _rowOpBusy = false;
      return;
    }
    if (!mounted) {
      _rowOpBusy = false;
      return;
    }
    if (existing.isEmpty) {
      context.appError('「${_goodsLabel(g)}」没有组件信息');
      _rowOpBusy = false;
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除组件信息'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${_goodsLabel(g)}」的全部 ${existing.length} 个组件吗？此操作不可恢复。',
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
    if (ok != true || !mounted) {
      _rowOpBusy = false;
      return;
    }
    var okCount = 0;
    for (final e in existing) {
      try {
        await repo.delete(g.id, e.id);
        okCount++;
      } catch (_) {}
    }
    if (!mounted) {
      _rowOpBusy = false;
      return;
    }
    context.appSuccess(
      okCount == existing.length
          ? '已删除全部 $okCount 个组件'
          : '已删除 $okCount/${existing.length} 个组件',
    );
    _rowOpBusy = false;
  }

  /// 行菜单条目（右击/长按弹出）。多选（选中 >1 且当前行在集合）→ 批量操作菜单
  /// （作用于选中集，修复"多选只复制一个"）；单行 → 单操作菜单。组件保证右键时
  /// 当前行已纳入选择集（未勾选行右键会先把选择集替换为仅该行）。
  List<UtenContextMenuEntry> _goodsMenuItems(GoodsListItem g) {
    final clip = widget.ref.read(goodsClipboardProvider);
    final selected = _selectedGoodsIds;
    if (selected.length > 1 && selected.contains(g.id)) {
      return _goodsBatchMenu(selected, clip);
    }
    final disabled = g.status == '禁用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showGoodsDetail(g.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '复制货品',
        icon: Icons.copy_rounded,
        onTap: () => _copyGoods(g),
      ),
      UtenMenuItem(
        label: '粘贴货品',
        icon: Icons.content_paste_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: _pasteGoods,
      ),
      UtenMenuItem(
        label: '批量粘贴…', // TODO(l10n): 补 arb
        icon: Icons.content_copy_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: _batchPasteGoodsMulti,
      ),
      UtenMenuItem(
        label: disabled ? '启用货品' : '禁用货品',
        icon: disabled
            ? Icons.play_circle_outline_rounded
            : Icons.pause_circle_outline_rounded,
        enabled: _canStatusMaster,
        destructive: !disabled,
        onTap: () => _toggleGoodsStatus(g),
      ),
      UtenMenuItem(
        label: '删除货品',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster,
        onTap: () => _deleteGoodsById(g.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '复制组件信息',
        icon: Icons.account_tree_outlined,
        onTap: () => _copyBom(g),
      ),
      UtenMenuItem(
        label: '粘贴组件信息',
        icon: Icons.content_paste_rounded,
        enabled: _canReplaceBom && (clip.bomItems?.isNotEmpty ?? false),
        onTap: () => _pasteBom(g),
      ),
      UtenMenuItem(
        label: '删除组件信息',
        icon: Icons.playlist_remove_rounded,
        destructive: true,
        enabled: _canBomDelete,
        onTap: () => _deleteBom(g),
      ),
    ];
  }

  /// 多选批量菜单：批量复制/粘贴组件/禁用/删除（作用于选中集）+ 粘贴货品/批量粘贴。
  List<UtenContextMenuEntry> _goodsBatchMenu(
    Set<String> selected,
    GoodsClipboardState clip,
  ) {
    final n = selected.length;
    return [
      UtenMenuItem(
        label: '批量复制($n)', // TODO(l10n): 补 arb
        icon: Icons.copy_all_rounded,
        enabled: _canCreateMaster,
        onTap: () => _batchCopyGoods(selected),
      ),
      UtenMenuItem(
        label: '批量粘贴组件($n)', // TODO(l10n): 补 arb
        icon: Icons.account_tree_outlined,
        enabled: _canReplaceBom && (clip.bomItems?.isNotEmpty ?? false),
        onTap: () => _batchPasteBom(selected),
      ),
      UtenMenuItem(
        label: '批量禁用($n)', // TODO(l10n): 补 arb
        icon: Icons.pause_circle_outline_rounded,
        enabled: _canStatusMaster,
        onTap: () => _batchSetGoodsStatus(selected, '禁用'),
      ),
      UtenMenuItem(
        label: '批量删除($n)', // TODO(l10n): 补 arb
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster,
        onTap: () => _batchDeleteGoods(selected),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '粘贴货品',
        icon: Icons.content_paste_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: _pasteGoods,
      ),
      UtenMenuItem(
        label: '批量粘贴…', // TODO(l10n): 补 arb
        icon: Icons.content_copy_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: _batchPasteGoodsMulti,
      ),
    ];
  }

  // ---- 多选批量操作（工具条批量操作区，有选中才显示） -----------------------

  List<Widget> _goodsBatchActions(BuildContext context, Set<String> ids) {
    // 批量操作已移至右键菜单（多选时显示批量项，见 _goodsBatchMenu）；工具条只保留
    // 「已选 N 项 + 取消选择」（组件 _buildBatchBar 在 actions 为空时即如此）。
    // 仍保留 batchActionsBuilder 传参，是为了让组件批量条常驻（显示已选计数 + ✕）。
    return const [];
  }

  /// 批量删除：确认后逐个删（容忍单条失败）；完成后清选择、刷新列表与特殊集合。
  Future<void> _batchDeleteGoods(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除货品'), // TODO(l10n): 补 arb
        content: Text('确定删除选中的 ${ids.length} 个货品吗？此操作不可恢复。'),
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
    final repo = widget.ref.read(goodsRepositoryProvider);
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
    setState(() => _selectedGoodsIds = {});
    context.appSuccess(
      '已删除 $okCount 个货品${failed.isNotEmpty ? '，${ids.length - okCount} 个失败' : ''}',
    );
    if (failed.isNotEmpty) context.appError(failed.first);
    await _loadGoods(_goodsPageNum);
    await _loadSpecialCollections();
  }

  /// 批量启停：逐条拉详情全量回传、仅改状态（无专用批量接口，复用单条更新）。
  Future<void> _batchSetGoodsStatus(Set<String> ids, String status) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(goodsRepositoryProvider);
    var okCount = 0;
    var skipped = 0;
    for (final id in ids) {
      try {
        final d = await repo.detail(id);
        if (d.status == status) {
          skipped++;
          continue;
        }
        await widget.ref
            .read(masterStatusRepositoryProvider)
            .change(
              resourcePath: ApiEndpoints.good(id),
              status: status,
              version: d.version,
            );
        okCount++;
      } catch (_) {
        skipped++;
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedGoodsIds = {});
    context.appSuccess(
      status == '禁用'
          ? '已禁用 $okCount 个货品${skipped > 0 ? '，$skipped 个跳过' : ''}'
          : '已启用 $okCount 个货品${skipped > 0 ? '，$skipped 个跳过' : ''}',
    );
    await _loadGoods(_goodsPageNum);
    await _loadSpecialCollections();
  }

  /// 批量复制：逐个拉详情快照进剪贴板货品槽（整批替换）；不依赖后端批量接口。
  Future<void> _batchCopyGoods(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final details = <GoodsDetail>[];
    for (final id in ids) {
      final d = await _fetchGoodsDetail(id);
      if (d != null) details.add(d);
    }
    _rowOpBusy = false;
    if (!mounted) return;
    if (details.isEmpty) {
      context.appError('复制失败：未能读取选中的货品'); // TODO(l10n): 补 arb
      return;
    }
    widget.ref.read(goodsClipboardProvider.notifier).copyGoodsList(details);
    setState(() => _selectedGoodsIds = {});
    context.appSuccess(
      '已复制 ${details.length} 个货品，可在目标分类下粘贴',
    ); // TODO(l10n): 补 arb
  }

  /// 批量粘贴：弹窗选每个货品粘贴份数，循环新建（编号自动生成）。
  Future<void> _batchPasteGoodsMulti() async {
    if (_rowOpBusy) return;
    final clips = widget.ref.read(goodsClipboardProvider).goodsList;
    if (clips.isEmpty) return;
    var copies = 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('批量粘贴货品'), // TODO(l10n): 补 arb
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('剪贴板有 ${clips.length} 个货品。'), // TODO(l10n): 补 arb
              const SizedBox(height: UtenSpacing.s12),
              Row(
                children: [
                  const Text('每个复制 '), // TODO(l10n): 补 arb
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: copies > 1 ? () => setSt(() => copies--) : null,
                  ),
                  Text(
                    '$copies',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: copies < 50 ? () => setSt(() => copies++) : null,
                  ),
                  const Text(' 份'), // TODO(l10n): 补 arb
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '共将生成 ${clips.length * copies} 个新货品(编号自动生成)', // TODO(l10n): 补 arb
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'), // TODO(l10n): 补 arb
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('粘贴'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(goodsRepositoryProvider);
    final taken = _loadedGoodsNames();
    var success = 0;
    var failed = 0;
    for (final d in clips) {
      for (var i = 0; i < copies; i++) {
        try {
          final body = _goodsSaveBody(d, copyMode: true);
          final newName = _pastedGoodsName(d.name, taken);
          if (newName.isNotEmpty) {
            body['name'] = newName;
            taken.add(newName);
          }
          await repo.create(body);
          success++;
        } catch (_) {
          failed++;
        }
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    if (success > 0) {
      context.appSuccess(
        '已粘贴生成 $success 个新货品${failed > 0 ? '，$failed 个失败' : ''}', // TODO(l10n): 补 arb
      );
      await _loadGoods(_goodsPageNum);
      await _loadSpecialCollections();
    } else {
      context.appError('粘贴失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// 批量粘贴组件信息：把剪贴板 BOM 粘到多个选中目标；统一选替换/追加。
  Future<void> _batchPasteBom(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final clip = widget.ref.read(goodsClipboardProvider);
    final items = clip.bomItems;
    if (items == null || items.isEmpty) return;
    final sourceLabel = clip.bomSourceLabel ?? '剪贴板';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量粘贴组件信息'), // TODO(l10n): 补 arb
        content: Text(
          '从「$sourceLabel」复制的 ${items.length} 个组件，'
          '如何粘贴到选中的 ${ids.length} 个货品？', // TODO(l10n): 补 arb
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, 'append'),
            child: const Text('同级追加'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, 'replace'),
            child: const Text('替换现有组件'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final replace = choice == 'replace';
    _rowOpBusy = true;
    var targetOk = 0;
    var totalComponents = 0;
    for (final id in ids) {
      final pasted = await _applyPasteBom(id, items, replace);
      if (pasted > 0) {
        targetOk++;
        totalComponents += pasted;
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedGoodsIds = {});
    if (targetOk > 0) {
      context.appSuccess(
        '已粘贴到 $targetOk 个货品，共 $totalComponents 个组件', // TODO(l10n): 补 arb
      );
    } else {
      context.appError('粘贴失败：组件均被跳过(重复或环路)'); // TODO(l10n): 补 arb
    }
  }

  // ---- 货品 新建/编辑/删除 ------------------------------------------------

  /// 添加货品：进新增整页（原弹窗太小）；返回后刷新当前页列表。
  Future<void> _showGoodsCreate() async {
    await context.push(RoutePath.basicinfoGoodsNew(widget.nodeId));
    if (!mounted) return;
    await _loadGoods(_goodsPageNum);
  }

  Future<void> _deleteGoods(GoodsDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除货品'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该货品')}」吗？', // TODO(l10n): 补 arb
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
      () async {
        await widget.ref.read(goodsRepositoryProvider).delete(d.id);
      },
      success: '货品已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadGoods(_goodsPageNum);
    // 删空当前页时回退上一页，避免列表显示空白
    if (mounted &&
        _goodsPage != null &&
        _goodsPage!.items.isEmpty &&
        _goodsPage!.page > 1) {
      await _loadGoods(_goodsPage!.page - 1);
    }
  }

  /// 点货品行：拉详情弹框展示核心字段。
  ///
  /// 用独立的 [_detailLoading] 防并发——不能用 [_goodsLoading]（那是分页列表
  /// 加载状态，列表加载完即恒为 false，起不到防连点作用）。否则并发触发
  /// showDialog 会让 Navigator 上多个对话框路由交错 push/pop，触发 element
  /// 生命周期断言（framework `_activateRecursively`：
  /// `_lifecycleState == _ElementLifecycle.inactive is not true`）。
  Future<void> _showImport() {
    return showGoodsImportDialog(
      context,
      widget.ref,
      onImported: () {
        _loadGoods(1);
        widget.onDataChanged();
      },
    );
  }

  /// 双击货品行：进货品详情整页（用户反馈原 920 宽弹窗太小）。
  ///
  /// 用 [_detailLoading] 防连点重复 push（快速双击-双击会压两个详情页）。
  /// 详情页内的编辑/删除/组装/成本变动不在进行中回传，统一在返回本页后
  /// 重载当前页列表（push 保活本页，返回即恢复到这里）。
  Future<void> _showGoodsDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    await context.push(RoutePath.basicinfoGoodsDetail(id));
    if (!mounted) return;
    _detailLoading = false;
    await _loadGoods(_goodsPageNum);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: _load,
      );
    }
    final d = _detail;
    if (d == null) {
      return Center(
        child: Text(
          '未选择分类', // TODO(l10n): 补 arb
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final isSystemRoot = isSystemUncategorizedCategory(
      systemManaged: d.systemManaged,
    );
    final canMutateCategory = canMutateMasterCategory(
      hasEditPermission: widget.canEdit,
      systemManaged: d.systemManaged,
    );
    // compact：容器 gutter 已提供水平留白；medium+：详情面板需自带水平内边距。
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final total = _goodsPage?.total ?? 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: UtenCollapsingHeaderScrollView(
        // 滚走区：分类信息卡（编辑/加子级/删除/导入/导出/打印）—— 上滑即收起、腾出表格空间。
        collapsingHeader: Padding(
          padding: const EdgeInsets.fromLTRB(
            0,
            UtenSpacing.s16,
            0,
            UtenSpacing.s12,
          ),
          child: MasterDetailCard(
            title: d.name,
            icon: Icons.inventory_2_outlined,
            subtitle:
                '编号前缀 ${d.effectivePrefix ?? 'HP'}${d.codePrefix == null ? '(继承)' : ''}'
                '${d.remark?.isNotEmpty == true ? ' · ${d.remark}' : ''} · 层级 L${d.level}',
            // 详情卡精简：不再展示统计行（子分类数/父级/旧编码）与路径行——
            // 左侧分类树已是主视觉，层级/父级/子项数树里都能看出，卡片只留标题+操作。
            stats: const [],
            canEdit: canMutateCategory,
            canAddChild: widget.canAddCategory,
            canDelete: widget.canDeleteCategory && !isSystemRoot,
            onAddChild: widget.onAddChild,
            onEdit: () {
              if (_detail != null) widget.onEdit(_detail!);
            },
            onDelete: widget.onDelete,
            deleteLabel: '删除分类', // TODO(l10n): 补 arb
            extraActions: [
              if (widget.canAddCategory && isSystemRoot)
                MasterDetailCardAction(
                  icon: Icons.add_rounded,
                  label: '新增子分类', // TODO(l10n): 补 arb
                  onPressed: widget.onAddChild,
                ),
            ],
            secondaryActions: [
              if ((widget.canEdit || widget.canDeleteCategory) && isSystemRoot)
                const SystemMasterCategoryProtectionNotice(),
              if (widget.ref
                  .read(currentPermissionsProvider)
                  .contains(Perm.goodsImport))
                UtenButton(
                  icon: Icons.file_upload_outlined,
                  onPressed: _showImport,
                  child: const Text('导入货品'), // TODO(l10n): 补 arb
                ),
              UtenPrintPreviewButton(
                title: '货品资料',
                subtitle: '最多前 2000 行',
                loader: _printLoader,
                exportEndpoint: '/master/goods/export',
                exportPermission: Perm.goodsExport,
                exportReport: '',
                exportQuery: _exportQuery,
                exportFilename: '货品资料',
              ),
              UtenExportButton(
                endpoint: '/master/goods/export',
                requiredPermission: Perm.goodsExport,
                report: '',
                queryParams: _exportQuery,
                filename: '货品资料',
                label: '导出货品',
              ),
            ],
          ),
        ),
        // body：货品标题 + 搜索 + 添加按钮（与原布局一致：添加在搜索右侧）+ 表格。
        // 卡片收起后这一行随 body 上移并自然吸顶，表格随之内滚。
        body: Column(
          children: [
            // 固定：货品标题 + 搜索 + 添加按钮
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '货品 ($total)', // TODO(l10n): 补 arb
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenSearchBar(
                      // key 含 nodeId + _kwSeed：切分类 / 树搜索写入关键词时重建搜索框同步显示。
                      key: ValueKey('goods-search-${widget.nodeId}-$_kwSeed'),
                      hint: '搜索货品(名称/编号/型号/规格/系列)', // TODO(l10n): 补 arb
                      initialValue: _keyword,
                      onChanged: _onKeywordChanged,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  // 预览打印 / 导出：已移入表格工具条（表头设置旁，深绿大按钮）。
                  if (_canCreateMaster) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.add_rounded,
                      onPressed: _showGoodsCreate,
                      child: const Text('添加货品'), // TODO(l10n): 补 arb
                    ),
                  ],
                ],
              ),
            ),
            // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）。
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动（拾取 NestedScrollView inner controller）。
            Expanded(
              child: MasterDataTableView<GoodsListItem>(
                primary: true,
                columns: _visibleGoodsColumns,
                items: _goodsPage?.items ?? const [],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: (g) => g.id,
                selectedIds: _selectedGoodsIds,
                onSelectedIdsChanged: (s) =>
                    setState(() => _selectedGoodsIds = s),
                batchActionsBuilder: _goodsBatchActions,
                // 行菜单（右击/长按）：复制/粘贴/启停/删除 + 组件信息复制/粘贴/删除。
                rowMenuBuilder: _goodsMenuItems,
                // 表头下前导分组：禁用货品（浅红）/ 不明货品（仅未分类节点）；展开后按本表
                // 同款列渲染，且「表头设置」列显隐对它同样生效。
                leadingGroups: _leadingGroups,
                facets: _facets?.fields ?? const {},
                nullCounts: _facets?.nullCounts ?? const {},
                filters: _filters,
                onFilterChanged: _onFilterChanged,
                // 行底色按使用状态：使用=浅蓝、禁用=浅红、其他=默认白；单击选中自动加深加亮。
                rowColor: (g) => switch (g.status) {
                  '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                  '禁用' => Colors.red.withValues(alpha: 0.10),
                  _ => null,
                },
                onRowTap: (g) => _showGoodsDetail(g.id),
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSortChange,
                isLoading: _goodsLoading && _goodsPage == null,
                loadingMore: _goodsLoading && _goodsPage != null,
                error: _goodsError,
                onRetry: () => _loadGoods(_goodsPageNum),
                emptyMessage: '该分类暂无货品', // TODO(l10n): 补 arb
                currentPage: _goodsPage?.page ?? 1,
                totalPages: _goodsPage?.totalPages ?? 1,
                onPageChange: (p) => _loadGoods(p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 货品列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 货品表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  /// 颜色/单位优先显示 UUID 关系解析出的名称；只有历史 UUID 缺失时才回显 legacy #id；价格作为末列。
  static final _goodsColumns = <MasterColumnDef<GoodsListItem>>[
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 120,
      sortable: true, // 全局唯一显示号但不是关系 id；高基数值用搜索，表头提供排序
      value: (g) => g.code,
    ),
    MasterColumnDef(
      key: 'series',
      label: '系列',
      width: 90,
      value: (g) => g.series,
    ),
    MasterColumnDef(
      key: 'model',
      label: '型号',
      width: 120,
      value: (g) => g.model,
    ),
    MasterColumnDef(
      key: 'name',
      label: '货品名称',
      width: 200,
      value: (g) => g.name,
    ),
    MasterColumnDef(key: 'spec', label: '规格', width: 150, value: (g) => g.spec),
    MasterColumnDef(
      key: 'colorLegacyId',
      label: '主颜色',
      width: 90,
      // legacy 0 是老库「未设置」哨兵（colors 表无 legacy_id=0），不是悬空引用，按空显示。
      value: (g) =>
          g.colorName ??
          (g.colorLegacyId == null || g.colorLegacyId == 0
              ? null
              : '#${g.colorLegacyId}'),
    ),
    MasterColumnDef(
      key: 'requireRemark',
      label: '备注',
      width: 180,
      value: (g) => g.requireRemark,
    ),
    MasterColumnDef(
      key: 'cNumber',
      label: '客户型号',
      width: 120,
      value: (g) => g.cNumber,
    ),
    MasterColumnDef(
      key: 'unitLegacyId',
      label: '单位',
      width: 70,
      value: (g) =>
          g.unitName ??
          (g.unitLegacyId == null || g.unitLegacyId == 0
              ? null
              : '#${g.unitLegacyId}'),
    ),
    MasterColumnDef(
      key: 'material',
      label: '材质',
      width: 120,
      value: (g) => g.material,
    ),
    MasterColumnDef(
      key: 'sourceType',
      label: '来源',
      width: 70,
      value: (g) => g.sourceType,
    ),
    MasterColumnDef(
      key: 'price',
      label: '价格',
      width: 100,
      type: 'money',
      sortable: true,
      value: (g) => g.price?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'discount',
      label: '折扣',
      width: 80,
      value: (g) => g.discount?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'stockQty',
      label: '库存量',
      width: 100,
      type: 'number',
      value: (g) => g.stockQty?.toStringAsFixed(2),
    ),
  ];
}
