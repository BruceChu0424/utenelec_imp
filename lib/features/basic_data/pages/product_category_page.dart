// 货品资料分类树管理页（基础资料）
//
// 顶层壳层(树加载/统一搜索/分类 CRUD)复用 CategoryPageShell；右侧明细区复用
// MasterEntityDetailPane(ADR-111：分页/筛选/排序/打印导出/启停/删除/批量命令只有一份)。
// 本页只保留货品特有的动作：复制/粘贴货品、组件信息的复制/粘贴/删除(粘贴与删除
// 都是服务端整批原子命令)、禁用/不明货品前导分组、导入与撤回导入。
// 编辑类按钮按 material_category:* / goods:* 权限显隐；查看全员可见(路由不设守卫)。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/03-页面/ 总览（基础资料）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/goods_bom_item.dart';
import '../models/product_category_node.dart';
import '../providers/goods_clipboard.dart';
import '../repositories/goods_bom_repository.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/goods_import_dialog.dart';
import '../models/goods_import.dart';
import '../repositories/goods_import_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_entity_detail_pane.dart';
import '../widgets/master_batch_feedback.dart';
import '../models/master_batch.dart';
import '../../../components/feedback/uten_dialog.dart';
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
    // 权限变化(登录恢复/管理员刷新授权)即整页重建：明细区按钮用 ref.read 取权限，随这里的 watch 联动。
    ref.watch(currentPermissionsProvider);
    return buildShell(
      context,
      detailPaneBuilder: (selected) =>
          MasterEntityDetailPane<GoodsListItem, GoodsDetail>(
            key: ValueKey('dp-${selected.id}-$_detailEpoch'),
            config: _paneConfig(),
            categoryId: selected.id,
            canEditCategory: shellCanEdit,
            canAddCategory: shellCanCreate,
            canDeleteCategory: shellCanDelete,
            externalKeyword: shellTreeSearchKeyword,
            onAddChild: () => shellShowCreateDialog(parent: selected),
            onEditCategory: (detail) => shellShowEditDialog(detail),
            onDeleteCategory: () => shellDeleteNode(selected),
          ),
    );
  }

  // ---- 权限 ------------------------------------------------------------------

  Set<String> get _perms => ref.read(currentPermissionsProvider);
  bool get _canCreateMaster => _perms.contains(Perm.goodsCreate);
  bool get _canDeleteMaster => _perms.contains(Perm.goodsDelete);
  bool get _canStatusMaster => _perms.contains(Perm.goodsStatus);
  bool get _canBomDelete => _perms.contains(Perm.goodsBomDelete);

  /// 替换粘贴要同时能新增、编辑、删除组件行(服务端替换还会再核一次删除权限)。
  bool get _canReplaceBom =>
      _perms.contains(Perm.goodsBomCreate) &&
      _perms.contains(Perm.goodsBomEdit) &&
      _canBomDelete;
  bool get _canEditPrice => _perms.contains(Perm.goodsPriceEdit);

  /// 无 goods:discount:view / goods:price:view(或 price:edit)者，折扣列/价格列整列移除
  /// (表头设置也不再列出)；后端同步把值置 null。
  List<MasterColumnDef<GoodsListItem>> get _visibleGoodsColumns {
    final canViewDiscount = _perms.contains(Perm.goodsDiscountView);
    final canViewPrice =
        _perms.contains(Perm.goodsPriceView) ||
        _perms.contains(Perm.goodsPriceEdit);
    return [
      for (final c in _goodsColumns)
        if ((c.key != 'discount' || canViewDiscount) &&
            (c.key != 'price' || canViewPrice))
          c,
    ];
  }

  /// 货品明细区配置：浏览态排除禁用/迁移占位(它们归表头下的前导分组)，
  /// 行菜单由本页接管(复制/粘贴/组件信息 + 多选批量菜单)。
  MasterEntityPaneConfig<GoodsListItem, GoodsDetail> _paneConfig() {
    final goods = ref.read(goodsRepositoryProvider);
    return MasterEntityPaneConfig<GoodsListItem, GoodsDetail>(
      noun: '货品', // TODO(l10n): 补 arb
      icon: Icons.inventory_2_outlined,
      defaultCodePrefix: 'HP',
      keyPrefix: 'goods',
      searchHint: '搜索货品(名称/编号/型号/规格/系列)', // TODO(l10n): 补 arb
      columns: _visibleGoodsColumns,
      idOf: (g) => g.id,
      statusOf: (g) => g.status,
      versionOf: (g) => g.version,
      labelOf: _goodsLabel,
      loadCategory: (id) =>
          ref.read(productCategoryRepositoryProvider).detail(id),
      loadPage: (q) => goods.list(
        q.categoryId,
        page: q.page,
        size: q.size ?? 20,
        keyword: q.keyword,
        filters: q.filters,
        sort: q.sort,
        order: q.order,
        // 浏览态禁用品归前导分组；搜索态把禁用品直接纳入结果，避免「定位到了但右侧为空」。
        excludeDisabled: q.forPrint || !q.hasKeyword,
        excludeStub: true, // 迁移兜底占位归「未分类」节点的集合行
      ),
      loadFacets: (id) async {
        final f = await goods.facets(id);
        return MasterPaneFacets(fields: f.fields, nullCounts: f.nullCounts);
      },
      batchEntityPath: ApiEndpoints.goods,
      statusResourceOf: ApiEndpoints.good,
      canCreate: _canCreateMaster,
      canEdit: _perms.contains(Perm.goodsEdit),
      canDelete: _canDeleteMaster,
      canStatus: _canStatusMaster,
      defaultSortKey: 'code',
      export: const MasterPaneExport(
        title: '货品资料', // TODO(l10n): 补 arb
        endpoint: '/master/goods/export',
        permission: Perm.goodsExport,
        label: '导出货品', // TODO(l10n): 补 arb
        extraQuery: {'excludeDisabled': true, 'excludeStub': true},
        inCard: true,
      ),
      cardActions: (pane) => [
        if (_perms.contains(Perm.goodsImport))
          UtenButton(
            icon: Icons.file_upload_outlined,
            onPressed: () => showGoodsImportDialog(
              context,
              ref,
              onImported: () {
                pane.reload(page: 1);
                shellReload();
              },
            ),
            child: const Text('导入货品'), // TODO(l10n): 补 arb
          ),
      ],
      onCreate: (pane) async {
        await context.push(RoutePath.basicinfoGoodsNew(pane.categoryId));
        // 新建货品编号最大，按编号正序落在列表最下面——跳到最后一页能看到它。
        if (mounted) await _reloadToLastPage(pane);
      },
      onOpen: _showGoodsDetail,
      rowMenuOverride: _goodsMenuItems,
      // 批量操作在右键菜单(多选时出批量项)；工具条只保留「已选 N 项 + 取消选择」。
      batchActionsOverride: (pane, ids) => const [],
      loadLeadingGroups: _leadingGroups,
    );
  }

  /// 表头下前导分组：禁用货品(当前分类子树)/不明货品(仅未分类节点，迁移占位无分类)。
  /// 主表已排除二者，不重复；搜索态不显示分组(禁用品直接进结果)。
  Future<List<MasterDataGroup<GoodsListItem>>> _leadingGroups(
    MasterPaneQuery query,
    ProductCategoryDetail category,
  ) async {
    if (query.hasKeyword) return const [];
    final repo = ref.read(goodsRepositoryProvider);
    final isOrphan = category.systemManaged;
    final results = await Future.wait<PagedResult<GoodsListItem>?>([
      repo.list(query.categoryId, disabledOnly: true, size: 500),
      isOrphan
          ? repo.list(null, stubOnly: true, size: 500)
          : Future<PagedResult<GoodsListItem>?>.value(),
    ]);
    final disabled = results[0];
    final stubs = results[1];
    return [
      if (disabled != null && disabled.total > 0)
        MasterDataGroup<GoodsListItem>(
          id: 'disabled',
          title: '禁用货品(${disabled.total})',
          subtitle: '当前分类子树内已停用的货品',
          icon: Icons.block_rounded,
          tint: Colors.red.withValues(alpha: 0.12),
          items: disabled.items,
          total: disabled.total,
        ),
      if (stubs != null && stubs.total > 0)
        MasterDataGroup<GoodsListItem>(
          id: 'stub',
          title: '不明货品(${stubs.total})',
          subtitle: '迁移兜底占位(auto_created)，无分类归属',
          icon: Icons.help_outline_rounded,
          tint: Colors.amber.withValues(alpha: 0.16),
          items: stubs.items,
          total: stubs.total,
        ),
    ];
  }

  // ---- 行菜单（右击/长按）：复制/粘贴/启停/删除 + 组件信息 ----------------

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
  Set<String> _loadedGoodsNames(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
  ) => {
    for (final g in pane.page?.items ?? const <GoodsListItem>[])
      if ((g.name ?? '').trim().isNotEmpty) g.name!.trim(),
  };

  /// 详情 → 保存请求体(复制粘贴用；字段与后端 GoodsSaveRequest 对齐)。
  /// [copyMode]=true 时不带编号（留空后端自动生成），且无 goods:price:edit 权限时
  /// 不带价格/折扣(后端对「新建带价」按触碰处理，会 403)。
  Map<String, dynamic> _goodsSaveBody(
    GoodsDetail d, {
    required String currentCategoryId,
    String? categoryId,
    String? status,
    bool copyMode = false,
  }) {
    final body = <String, dynamic>{
      'categoryId': resolveGoodsSaveCategoryId(
        currentCategoryId: currentCategoryId,
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
      // 后模镶件编号 + 备注(老库 Paper 真身)：粘贴等全量回传路径同步携带。
      'rearInsertCode': d.rearInsertCode,
      'paper': d.paper,
      'pack': d.pack,
      'pieces': d.pieces,
      // 采购批量口径(V575)：与其他字段同口径全量回传，避免粘贴清空。
      'minOrderQty': d.minOrderQty,
      'orderMultipleQty': d.orderMultipleQty,
      // 所属仓库 (V587)：本 body 是整体覆盖式回传，漏带这一键在复制/粘贴时就会把归属丢掉。
      'owningWarehouseId': d.owningWarehouseId,
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
      // ADR-098 委外允许损耗记忆：整体覆盖式回传原样带回，粘贴不清空。
      'subcontractAllowedLossPct': d.subcontractAllowedLossPct,
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

  /// BOM 行 → 粘贴请求行(字段与后端 BomItemSaveRequest 对齐)。
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

  /// 「复制货品」：整份详情 + 全部组件行一起快照进 App 内剪贴板（全量复制）。
  Future<void> _copyGoods(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) async {
    final clip = await pane.runExclusive(() async {
      final d = await context.guardLoad(
        () => ref.read(goodsRepositoryProvider).detail(g.id),
        errorFallback: '加载货品详情失败', // TODO(l10n): 补 arb
      );
      if (d == null) return null;
      // 组件行读取失败不打断复制：货品字段照常复制，组件留空并说明原因。
      List<GoodsBomItem> bom = const [];
      try {
        bom = await ref.read(goodsBomRepositoryProvider).list(g.id);
      } on ApiException catch (e) {
        if (mounted) {
          context.appError('组件信息没有复制成功：${e.message}'); // TODO(l10n): 补 arb
        }
      }
      return GoodsCopyClip(detail: d, bomItems: bom);
    });
    if (clip == null || !mounted) return;
    ref.read(goodsClipboardProvider.notifier).copyGoods(clip);
    final d = clip.detail;
    context.appSuccess(
      '已复制货品「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '')}」'
      '${clip.bomItems.isEmpty ? '' : '(含 ${clip.bomItems.length} 个组件)'}，可在目标分类下粘贴',
    );
  }

  /// 按剪贴板快照在当前分类下新建货品(编号自动生成，名称加「(n)」副本标记)，
  /// 随后把快照里的组件行原样粘到新货品上(全量复制)。每个新货品两次请求
  /// (新建货品 + 服务端原子粘组件)；失败的逐条说明原因，不吞掉。
  /// 完成后跳到列表最后一页——列表按编号正序，新副本编号最大，落在最下面。
  Future<void> _pasteGoodsCopies(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane, {
    required int copies,
  }) async {
    final clips = ref.read(goodsClipboardProvider).goodsList;
    if (clips.isEmpty) return;
    final bomRepo = ref.read(goodsBomRepositoryProvider);
    final outcome = await pane.runExclusive(() async {
      final repo = ref.read(goodsRepositoryProvider);
      final taken = _loadedGoodsNames(pane);
      final results = <MasterBatchItemResult>[];
      var seq = 0;
      for (final clip in clips) {
        final d = clip.detail;
        for (var i = 0; i < copies; i++) {
          final body = _goodsSaveBody(
            d,
            currentCategoryId: pane.categoryId,
            copyMode: true,
          );
          final newName = _pastedGoodsName(d.name, taken);
          if (newName.isNotEmpty) {
            body['name'] = newName;
            taken.add(newName);
          }
          final label = newName.isNotEmpty ? newName : (d.name ?? '货品');
          try {
            final created = await repo.create(body);
            results.add(
              MasterBatchItemResult(id: '${seq++}', label: label, ok: true),
            );
            // 全量复制：把源货品组件行粘到新货品(新货品没有组件，追加=替换等价)。
            // 组件粘失败单独成行报原因——货品本体已建成功，不并在一起误报整条失败。
            if (clip.bomItems.isNotEmpty) {
              try {
                await bomRepo.paste(
                  mode: BomPasteMode.append,
                  targets: [BomPasteTarget(created.id)],
                  items: [for (final it in clip.bomItems) _bomSaveBody(it)],
                );
              } on ApiException catch (e) {
                results.add(
                  MasterBatchItemResult(
                    id: '${seq++}',
                    label: '「$label」的组件',
                    ok: false,
                    reason: e.message,
                  ),
                );
              }
            }
          } on ApiException catch (e) {
            results.add(
              MasterBatchItemResult(
                id: '${seq++}',
                label: label,
                ok: false,
                reason: e.message,
              ),
            );
          }
        }
      }
      final ok = results.where((r) => r.ok).length;
      return MasterBatchResult(
        succeeded: ok,
        failed: results.length - ok,
        results: results,
      );
    });
    if (outcome == null || !mounted) return;
    await showMasterBatchOutcome(context, outcome, action: '粘贴', noun: '货品');
    if (mounted && outcome.succeeded > 0) await _reloadToLastPage(pane);
  }

  /// 重载并跳到最后一页：新建/粘贴的货品编号最大，按编号正序排在列表最下面。
  Future<void> _reloadToLastPage(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
  ) async {
    await pane.reload();
    final last = pane.page?.totalPages ?? 1;
    if (last > 1) await pane.reload(page: last);
  }

  /// 批量粘贴：弹窗选每个货品粘贴份数，再逐个新建(编号自动生成)。
  Future<void> _batchPasteGoodsMulti(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
  ) async {
    if (pane.busy) return;
    final clips = ref.read(goodsClipboardProvider).goodsList;
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
    await _pasteGoodsCopies(pane, copies: copies);
  }

  /// 批量复制：逐个拉「详情 + 组件行」快照进剪贴板货品槽(整批替换，全量复制)；
  /// 读失败的逐条说明。
  Future<void> _batchCopyGoods(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    Set<String> ids,
  ) async {
    if (ids.isEmpty) return;
    final clips = await pane.runExclusive(() async {
      final goodsRepo = ref.read(goodsRepositoryProvider);
      final bomRepo = ref.read(goodsBomRepositoryProvider);
      final out = <GoodsCopyClip>[];
      final failed = <String>[];
      for (final id in ids) {
        try {
          final d = await goodsRepo.detail(id);
          // 组件行读取失败不打断该货品的复制：字段照常复制，组件留空并说明。
          List<GoodsBomItem> bom = const [];
          try {
            bom = await bomRepo.list(id);
          } on ApiException catch (e) {
            failed.add('「${_goodsLabelById(pane, id)}」的组件没有复制：${e.message}');
          }
          out.add(GoodsCopyClip(detail: d, bomItems: bom));
        } on ApiException catch (e) {
          failed.add(e.message);
        }
      }
      if (failed.isNotEmpty && mounted) {
        context.appError(
          '有 ${failed.length} 项没有复制：${failed.toSet().join('；')}', // TODO(l10n): 补 arb
        );
      }
      return out;
    });
    if (clips == null || !mounted || clips.isEmpty) return;
    ref.read(goodsClipboardProvider.notifier).copyGoodsList(clips);
    pane.clearSelection();
    context.appSuccess(
      '已复制 ${clips.length} 个货品(含组件)，可在目标分类下粘贴', // TODO(l10n): 补 arb
    );
  }

  /// 按列表行 id 取展示名（批量复制失败提示用）。
  String _goodsLabelById(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    String id,
  ) {
    for (final g in pane.page?.items ?? const <GoodsListItem>[]) {
      if (g.id == id) return _goodsLabel(g);
    }
    return '货品';
  }

  /// 「复制组件信息」：把该货品的 BOM 行快照进剪贴板。
  Future<void> _copyBom(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) async {
    final items = await pane.runExclusive(
      () => context.guardLoad(
        () => ref.read(goodsBomRepositoryProvider).list(g.id),
        errorFallback: '读取组件信息失败', // TODO(l10n): 补 arb
      ),
    );
    if (items == null || !mounted) return;
    if (items.isEmpty) {
      context.appError('「${_goodsLabel(g)}」没有组件信息可复制');
      return;
    }
    ref.read(goodsClipboardProvider.notifier).copyBom(items, _goodsLabel(g));
    context.appSuccess('已复制 ${items.length} 个组件，可在目标货品上粘贴');
  }

  /// 粘贴组件信息到一个或多个目标：服务端一次请求、一个事务(ADR-111)——
  /// 任何一处不合格(重复/成环/组件停用/目标已被他人改过)一条都不写，逐条说明原因。
  Future<void> _submitBomPaste(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane, {
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<GoodsBomItem> items,
  }) async {
    final result = await pane.runExclusive(
      () => context.guardAction(
        () => ref
            .read(goodsBomRepositoryProvider)
            .paste(
              mode: mode,
              targets: targets,
              items: [for (final it in items) _bomSaveBody(it)],
            ),
        errorFallback: '粘贴失败，请稍后重试', // TODO(l10n): 补 arb
      ),
    );
    if (result == null || !mounted) return;
    pane.clearSelection();
    context.appSuccess(
      mode == BomPasteMode.replace
          ? '已替换 ${result.targets} 个货品的组件，共 ${result.added} 个' // TODO(l10n): 补 arb
          : '已给 ${result.targets} 个货品追加 ${result.added} 个组件', // TODO(l10n): 补 arb
    );
  }

  /// 「粘贴组件信息」：目标已有组件时让用户选「替换」或「同级追加」；
  /// 读到的现有组件行作为版本一起提交，期间被他人改过就整批拒绝。
  Future<void> _pasteBom(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) async {
    final clip = ref.read(goodsClipboardProvider);
    final items = clip.bomItems;
    if (items == null || items.isEmpty || pane.busy) return;
    final existing = await pane.runExclusive(
      () => context.guardLoad(
        () => ref.read(goodsBomRepositoryProvider).list(g.id),
        errorFallback: '读取目标货品组件信息失败', // TODO(l10n): 补 arb
      ),
    );
    if (existing == null || !mounted) return;
    final sourceLabel = clip.bomSourceLabel ?? '剪贴板';
    var mode = BomPasteMode.append;
    if (existing.isNotEmpty) {
      final choice = await _askBomPasteMode(
        '「${_goodsLabel(g)}」已有 ${existing.length} 个组件。\n'
        '从「$sourceLabel」复制的 ${items.length} 个组件要如何粘贴？',
      );
      if (choice == null || !mounted) return;
      mode = choice;
    } else {
      final ok = await UtenDialog.show(
        context,
        title: '粘贴组件信息', // TODO(l10n): 补 arb
        content: Text(
          '将从「$sourceLabel」复制的 ${items.length} 个组件粘贴到「${_goodsLabel(g)}」？',
        ),
        confirmLabel: '粘贴', // TODO(l10n): 补 arb
      );
      if (ok != true || !mounted) return;
    }
    await _submitBomPaste(
      pane,
      mode: mode,
      targets: [
        BomPasteTarget(g.id, expectedItemIds: [for (final e in existing) e.id]),
      ],
      items: items,
    );
  }

  /// 批量粘贴组件信息：把剪贴板 BOM 一次粘到多个选中目标；统一选替换/追加。
  Future<void> _batchPasteBom(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    Set<String> ids,
  ) async {
    final clip = ref.read(goodsClipboardProvider);
    final items = clip.bomItems;
    if (ids.isEmpty || items == null || items.isEmpty || pane.busy) return;
    final choice = await _askBomPasteMode(
      '从「${clip.bomSourceLabel ?? '剪贴板'}」复制的 ${items.length} 个组件，'
      '如何粘贴到选中的 ${ids.length} 个货品？', // TODO(l10n): 补 arb
    );
    if (choice == null || !mounted) return;
    await _submitBomPaste(
      pane,
      mode: choice,
      targets: [for (final id in ids) BomPasteTarget(id)],
      items: items,
    );
  }

  Future<BomPasteMode?> _askBomPasteMode(String message) =>
      showDialog<BomPasteMode>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('粘贴组件信息'), // TODO(l10n): 补 arb
          content: Text(message),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'), // TODO(l10n): 补 arb
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, BomPasteMode.append),
              child: const Text('同级追加'), // TODO(l10n): 补 arb
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
              onPressed: () => Navigator.pop(ctx, BomPasteMode.replace),
              child: const Text('替换现有组件'), // TODO(l10n): 补 arb
            ),
          ],
        ),
      );

  /// 「删除组件信息」：确认后一次请求删除该货品的全部 BOM 行(整批原子)。
  Future<void> _deleteBom(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) async {
    if (pane.busy) return;
    final existing = await pane.runExclusive(
      () => context.guardLoad(
        () => ref.read(goodsBomRepositoryProvider).list(g.id),
        errorFallback: '读取组件信息失败', // TODO(l10n): 补 arb
      ),
    );
    if (existing == null || !mounted) return;
    if (existing.isEmpty) {
      context.appError('「${_goodsLabel(g)}」没有组件信息');
      return;
    }
    final ok = await UtenDialog.show(
      context,
      title: '删除组件信息', // TODO(l10n): 补 arb
      content: Text(
        '确定删除「${_goodsLabel(g)}」的全部 ${existing.length} 个组件吗？此操作不可恢复。',
      ),
      confirmLabel: '删除', // TODO(l10n): 补 arb
      danger: true,
    );
    if (ok != true || !mounted) return;
    final deleted = await pane.runExclusive(
      () => context.guardAction(
        () => ref.read(goodsBomRepositoryProvider).deleteMany(g.id, [
          for (final e in existing) e.id,
        ]),
        errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
      ),
    );
    if (deleted != null && mounted) {
      context.appSuccess('已删除全部 $deleted 个组件'); // TODO(l10n): 补 arb
    }
  }

  /// 行菜单条目（右击/长按弹出）。多选（选中 >1 且当前行在集合）→ 批量操作菜单
  /// (作用于选中集)；单行 → 单操作菜单。组件保证右键时当前行已纳入选择集。
  List<UtenContextMenuEntry> _goodsMenuItems(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) {
    final clip = ref.read(goodsClipboardProvider);
    final selected = pane.selectedIds;
    if (selected.length > 1 && selected.contains(g.id)) {
      return _goodsBatchMenu(pane, selected, clip);
    }
    final disabled = g.status == '禁用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showGoodsDetail(pane, g),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '复制货品',
        icon: Icons.copy_rounded,
        onTap: () => _copyGoods(pane, g),
      ),
      UtenMenuItem(
        label: '粘贴货品',
        icon: Icons.content_paste_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: () => _pasteGoodsCopies(pane, copies: 1),
      ),
      UtenMenuItem(
        label: '批量粘贴…', // TODO(l10n): 补 arb
        icon: Icons.content_copy_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: () => _batchPasteGoodsMulti(pane),
      ),
      UtenMenuItem(
        label: disabled ? '启用货品' : '禁用货品',
        icon: disabled
            ? Icons.play_circle_outline_rounded
            : Icons.pause_circle_outline_rounded,
        enabled: _canStatusMaster,
        destructive: !disabled,
        onTap: () => pane.toggleStatus(g),
      ),
      UtenMenuItem(
        label: '删除货品',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster,
        onTap: () => pane.batchDelete({g.id}),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '复制组件信息',
        icon: Icons.account_tree_outlined,
        onTap: () => _copyBom(pane, g),
      ),
      UtenMenuItem(
        label: '粘贴组件信息',
        icon: Icons.content_paste_rounded,
        enabled: _canReplaceBom && (clip.bomItems?.isNotEmpty ?? false),
        onTap: () => _pasteBom(pane, g),
      ),
      UtenMenuItem(
        label: '删除组件信息',
        icon: Icons.playlist_remove_rounded,
        destructive: true,
        enabled: _canBomDelete,
        onTap: () => _deleteBom(pane, g),
      ),
    ];
  }

  /// 多选批量菜单：批量复制/粘贴组件/禁用/启用/删除(作用于选中集)+ 粘贴货品/批量粘贴。
  List<UtenContextMenuEntry> _goodsBatchMenu(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    Set<String> selected,
    GoodsClipboardState clip,
  ) {
    final n = selected.length;
    return [
      UtenMenuItem(
        label: '批量复制($n)', // TODO(l10n): 补 arb
        icon: Icons.copy_all_rounded,
        enabled: _canCreateMaster,
        onTap: () => _batchCopyGoods(pane, selected),
      ),
      UtenMenuItem(
        label: '批量粘贴组件($n)', // TODO(l10n): 补 arb
        icon: Icons.account_tree_outlined,
        enabled: _canReplaceBom && (clip.bomItems?.isNotEmpty ?? false),
        onTap: () => _batchPasteBom(pane, selected),
      ),
      UtenMenuItem(
        label: '批量禁用($n)', // TODO(l10n): 补 arb
        icon: Icons.pause_circle_outline_rounded,
        enabled: _canStatusMaster,
        onTap: () => pane.batchSetStatus(selected, '禁用'),
      ),
      UtenMenuItem(
        label: '批量启用($n)', // TODO(l10n): 补 arb
        icon: Icons.play_circle_outline_rounded,
        enabled: _canStatusMaster,
        onTap: () => pane.batchSetStatus(selected, '使用'),
      ),
      UtenMenuItem(
        label: '批量删除($n)', // TODO(l10n): 补 arb
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster,
        onTap: () => pane.batchDelete(selected),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '粘贴货品',
        icon: Icons.content_paste_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: () => _pasteGoodsCopies(pane, copies: 1),
      ),
      UtenMenuItem(
        label: '批量粘贴…', // TODO(l10n): 补 arb
        icon: Icons.content_copy_rounded,
        enabled: _canCreateMaster && clip.hasGoods,
        onTap: () => _batchPasteGoodsMulti(pane),
      ),
    ];
  }

  /// 双击货品行：进货品详情整页；[_detailOpening] 防快速双击压两个详情页。
  /// 详情页内的编辑/删除/组装/成本变动统一在返回本页后重载当前页列表。
  bool _detailOpening = false;

  Future<void> _showGoodsDetail(
    MasterEntityPaneController<GoodsListItem, GoodsDetail> pane,
    GoodsListItem g,
  ) async {
    if (_detailOpening) return;
    _detailOpening = true;
    try {
      await context.push(RoutePath.basicinfoGoodsDetail(g.id));
    } finally {
      _detailOpening = false;
    }
    if (mounted) await pane.reload();
  }

  // ---- 货品列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 货品表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  /// 颜色/单位优先显示 UUID 关系解析出的名称；只有历史 UUID 缺失时才回显 legacy #id；价格作为末列。
  static final _goodsColumns = <MasterColumnDef<GoodsListItem>>[
    MasterColumnDef(
      key: 'name',
      label: '货品名称',
      width: 200,
      value: (g) => g.name,
    ),
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 120,
      sortable: true, // 全局唯一显示号但不是关系 id；高基数值用搜索，表头提供排序
      value: (g) => g.code,
    ),
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
      key: 'series',
      label: '系列',
      width: 90,
      value: (g) => g.series,
    ),
    // 所属仓库 (V587)：货品平时归哪个仓管的主档归属，不是单据落点仓。
    // 这里只读展示，改归属在货品详情页的「基本信息」里做。
    MasterColumnDef(
      key: 'owningWarehouse',
      label: '所属仓库',
      width: 120,
      info:
          '货品平时归哪个仓管的主档归属，不是单据落点仓，也不是物料分析的分析范围仓。'
          '任何入库都会自动把它更新为最新入库仓。',
      value: (g) => g.owningWarehouseName,
    ),
    // 归属生产车间 (V590)：最近一次排产确认/车间改派自动学习回写，只读展示。
    MasterColumnDef(
      key: 'owningWorkshop',
      label: '归属车间',
      width: 120,
      info:
          '这个货品归哪个生产车间生产。最近一次排产确认或车间改派会自动记住，'
          '下次下达车间默认带出。',
      value: (g) => g.owningWorkshopName,
    ),
    MasterColumnDef(
      key: 'model',
      label: '型号',
      width: 120,
      value: (g) => g.model,
    ),
    MasterColumnDef(key: 'spec', label: '规格', width: 150, value: (g) => g.spec),
    MasterColumnDef(
      key: 'paper',
      label: '备注',
      width: 180,
      // 老系统「备注」列即 B_Goods.Paper（新库 goods.paper）；require_remark 是
      // Require 列迁移残值（真实迁移恒空），仅作兜底回显。
      value: (g) => g.paper ?? g.requireRemark,
    ),
    MasterColumnDef(
      key: 'cNumber',
      label: '客户型号',
      width: 120,
      value: (g) => g.cNumber,
    ),
    MasterColumnDef(
      key: 'mouldCode',
      label: '模具编号',
      width: 130,
      value: (g) => g.mouldCode,
    ),
    MasterColumnDef(
      key: 'rearInsertCode',
      label: '后模镶件编号',
      width: 110,
      // 生产该货品需更换的后模镶件标识（老备注解析迁移；空=无需换件或待人工补录）。
      value: (g) => g.rearInsertCode,
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
    // 采购批量口径（V575）：空=供应商无该项要求，按净需求原样下达。
    MasterColumnDef(
      key: 'minOrderQty',
      label: '最小起订量',
      width: 100,
      type: 'number',
      value: (g) => goodsQtyText(g.minOrderQty),
    ),
    MasterColumnDef(
      key: 'orderMultipleQty',
      label: '订货倍数',
      width: 90,
      type: 'number',
      value: (g) => goodsQtyText(g.orderMultipleQty),
    ),
  ];
}
