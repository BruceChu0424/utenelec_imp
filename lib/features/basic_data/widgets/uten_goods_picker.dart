// UtenGoodsPicker - 货品选择器（单据明细/报表选货品用）。
//
// 触发：函数式 showUtenGoodsPicker(context, ref) → 返回 GoodsListItem?。
// 形态仿 UtenDepartmentPicker：compact 底部抽屉（85% 屏高）/ medium+ 右侧滑入 720 宽面板。
// 内容：左分类树（UtenCategoryTreeView，排除原材料/辅料/未分类）+ 右货品列表（搜索+分页）。
// 点货品行即选中返回。分类树来自 productCategoryRepositoryProvider.tree()，货品来自
// goodsRepositoryProvider.list(分类子树)/search(全库)。
//
// 与旧 sales_goods_picker / goods_picker_dialog（居中搜索框）的区别：带分类树浏览、
// 返回完整 GoodsListItem（含 colorLegacyId/unitLegacyId/colorName/unitName），供调用方
// 自动回填颜色/单位。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/product_category_node.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import 'uten_category_tree_view.dart';

/// 货品选择器排除的根分类 legacyId（来自后端 material_categories 种子）：
/// 原材料=2113、辅料=2480、未分类=迁移虚拟孤儿根 -1。
const _excludedLegacyIds = {2113, 2480, -1};

/// 滑窗显示范围（按单据场景分流；默认 sellable 保持历史行为，零回归）。
enum UtenGoodsPickerScope {
  /// 成品/可售卖类：排除原材料/辅料/未分类（销售/生产/委外进仓等）。
  sellable,

  /// 原材料/辅料类：只保留原材料/辅料子树（采购/领料/物料反查等）。
  material,

  /// 全部：不过滤（调拨/其它出入库/盘点）。
  all,

  /// 组件选择（BOM 组装信息用）：只保留 原材料/半成品/辅料/OEM成品/OEM物料/OEM功能件 子树。
  component,

  /// 仅原材料（不含辅料）：货品「包装」字段选材料专用，比 [material] 更窄。
  rawMaterial,

  /// 除未分类外全部：只排除"未分类"孤儿根，原材料/辅料/半成品等其余分类都保留
  /// （问题 #17：销售订货明细选货品此前误用 [sellable] 把原材料也过滤掉了）。
  allExceptUncategorized,
}

/// 未分类（迁移虚拟孤儿根）legacyId。
const _uncategorizedLegacyId = -1;

/// 节点是否为"未分类"根。
bool _isUncategorizedRoot(ProductCategoryNode n) {
  if (n.legacyId == _uncategorizedLegacyId) return true;
  return n.name.contains('未分类');
}

/// allExceptUncategorized 范围：过滤掉"未分类"子树，其余原样保留。
List<ProductCategoryNode> _filterUncategorizedTree(
  List<ProductCategoryNode> nodes,
) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isUncategorizedRoot(n)) continue;
    out.add(
      ProductCategoryNode(
        id: n.id,
        code: n.code,
        name: n.name,
        level: n.level,
        parentId: n.parentId,
        sortOrder: n.sortOrder,
        legacyId: n.legacyId,
        children: _filterUncategorizedTree(n.children),
      ),
    );
  }
  return out;
}

/// material 范围保留的根分类 legacyId（原材料/辅料）。
/// 扩展点：若包装材料/五金配件是独立根且采购/领料需要，再加 legacyId 与下方关键字。
const _materialRootLegacyIds = {2113, 2480};
const _materialRootNameKeywords = {'原材料', '辅料'};

/// component 范围保留的根分类 legacyId（BOM 组件选择器）：
/// 原材料 2113 / 半成品 2149 / 辅料 2480 / OEM成品 2304 / OEM物料 2305 / OEM功能件 2460。
/// legacyId 源：docs/数据迁移/02-货品分类-老库溯源.md §3.1 九根节点。
const _componentRootLegacyIds = {2113, 2149, 2480, 2304, 2305, 2460};
const _componentRootNameKeywords = {'原材料', '半成品', '辅料', 'OEM'};

/// 名称兜底判断（legacyId 缺失或新增同名分类时仍能排除）。
bool _isExcludedCategory(ProductCategoryNode n) {
  if (n.legacyId != null && _excludedLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return name.contains('原材料') || name.contains('辅料') || name.contains('未分类');
}

/// 递归过滤分类树：命中排除规则的节点整子树丢弃；其余保留并对 children 递归过滤。
/// 返回新森林副本，不影响调用方原树（如货品资料页直接用 productCategoryRepositoryProvider.tree()）。
List<ProductCategoryNode> _filterExcludedTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isExcludedCategory(n)) continue; // 整子树丢弃
    out.add(
      ProductCategoryNode(
        id: n.id,
        code: n.code,
        name: n.name,
        level: n.level,
        parentId: n.parentId,
        sortOrder: n.sortOrder,
        legacyId: n.legacyId,
        children: _filterExcludedTree(n.children),
      ),
    );
  }
  return out;
}

/// 节点是否属于 material 范围根（原材料/辅料）。
bool _isMaterialRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _materialRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return _materialRootNameKeywords.any(name.contains);
}

/// material 范围：只保留命中（原材料/辅料）的节点整子树。
/// 命中节点的非命中祖先丢弃（命中节点升为新森林的根）。是 _filterExcludedTree 的逆操作。
List<ProductCategoryNode> _keepMaterialTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isMaterialRoot(n)) {
      // 命中：整子树保留（命中节点下所有子分类都算材料，不再过滤 children）。
      out.add(_cloneSubtree(n));
    } else {
      // 未命中：递归往下找命中的后代（后代升为新森林根）。
      out.addAll(_keepMaterialTree(n.children));
    }
  }
  return out;
}

/// 节点是否属于 component 范围根（原材料/半成品/辅料/OEM 系列）。
bool _isComponentRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _componentRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return _componentRootNameKeywords.any(name.contains);
}

/// component 范围（BOM 组件选择器）：只保留命中的节点整子树，与 _keepMaterialTree 同构。
List<ProductCategoryNode> _keepComponentTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isComponentRoot(n)) {
      out.add(_cloneSubtree(n));
    } else {
      out.addAll(_keepComponentTree(n.children));
    }
  }
  return out;
}

/// rawMaterial 范围保留的根分类 legacyId（原材料，不含辅料）。
const _rawMaterialRootLegacyIds = {2113};

/// 节点是否属于原材料根（不含辅料，与名称含"辅料"区分）。
bool _isRawMaterialRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _rawMaterialRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  return n.name.contains('原材料');
}

/// rawMaterial 范围：只保留原材料子树，与 _keepMaterialTree 同构但排除辅料。
List<ProductCategoryNode> _keepRawMaterialTree(
  List<ProductCategoryNode> nodes,
) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isRawMaterialRoot(n)) {
      out.add(_cloneSubtree(n));
    } else {
      out.addAll(_keepRawMaterialTree(n.children));
    }
  }
  return out;
}

/// 深拷贝整子树（命中节点保留全部后代用）。
ProductCategoryNode _cloneSubtree(ProductCategoryNode n) {
  return ProductCategoryNode(
    id: n.id,
    code: n.code,
    name: n.name,
    level: n.level,
    parentId: n.parentId,
    sortOrder: n.sortOrder,
    legacyId: n.legacyId,
    children: [for (final c in n.children) _cloneSubtree(c)],
  );
}

/// 弹出货品选择器，返回所选货品（完整 GoodsListItem）；取消返回 null。
///
/// [requireConfirm]：默认 false（点行即选中并关闭，历史行为）。设 true 时点行只是勾选高亮，
/// 需再点底部「确定」才返回；点右上角关闭/遮罩视为取消（包装选料等需要二次确认的场景用）。
Future<GoodsListItem?> showUtenGoodsPicker(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.sellable,
  bool requireConfirm = false,
}) {
  return _presentSheet<GoodsListItem>(
    context,
    ref,
    scope,
    multiSelect: false,
    requireConfirm: requireConfirm,
  ).then((r) => r is GoodsListItem ? r : null);
}

/// 多选货品选择器：点货品行勾选/取消，底部「确定(N)」返回所选列表；取消返回空列表。
/// 供 BOM 组装信息「一个层级添加多个组件」批量录入用。
Future<List<GoodsListItem>> showUtenGoodsPickerMulti(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.component,
}) async {
  final r = await _presentSheet<List<GoodsListItem>>(
    context,
    ref,
    scope,
    multiSelect: true,
  );
  return r ?? const <GoodsListItem>[];
}

Future<T?> _presentSheet<T>(
  BuildContext context,
  WidgetRef ref,
  UtenGoodsPickerScope scope, {
  required bool multiSelect,
  bool requireConfirm = false,
}) async {
  List<ProductCategoryNode> tree;
  try {
    final raw = await ref.read(productCategoryRepositoryProvider).tree();
    tree = switch (scope) {
      UtenGoodsPickerScope.sellable => _filterExcludedTree(raw),
      UtenGoodsPickerScope.material => _keepMaterialTree(raw),
      UtenGoodsPickerScope.all => raw,
      UtenGoodsPickerScope.component => _keepComponentTree(raw),
      UtenGoodsPickerScope.rawMaterial => _keepRawMaterialTree(raw),
      UtenGoodsPickerScope.allExceptUncategorized => _filterUncategorizedTree(
        raw,
      ),
    };
  } catch (_) {
    if (context.mounted) context.appError('货品分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _GoodsPickerSheet(
    tree: tree,
    scope: scope,
    multiSelect: multiSelect,
    requireConfirm: requireConfirm,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.85,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 720, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _GoodsPickerSheet extends ConsumerStatefulWidget {
  const _GoodsPickerSheet({
    required this.tree,
    required this.scope,
    this.multiSelect = false,
    this.requireConfirm = false,
  });
  final List<ProductCategoryNode> tree;
  final UtenGoodsPickerScope scope;
  final bool multiSelect;

  /// 单选模式下是否需要底部「确定」二次确认（而非点行即关闭）。多选模式恒需确认，此项无效。
  final bool requireConfirm;

  @override
  ConsumerState<_GoodsPickerSheet> createState() => _GoodsPickerSheetState();
}

class _GoodsPickerSheetState extends ConsumerState<_GoodsPickerSheet> {
  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  Timer? _debounce;
  int _page = 1;
  PagedResult<GoodsListItem>? _paged;
  bool _loading = false;
  String? _error;

  /// 多选模式下已勾选的货品（id → 完整 item）。
  final Map<String, GoodsListItem> _selected = {};

  @override
  void initState() {
    super.initState();
    // 懒载：预选第一个根分类（树高亮，用户有定位感），但不立即加载货品列表。
    // 输关键词或点分类才加载（省资源）。
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    setState(() {
      _selectedCategoryId = node.id;
      _page = 1;
    });
    _reloadGoods();
  }

  void _onKeywordChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _page = 1);
      _reloadGoods();
    });
  }

  Future<void> _reloadGoods() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kw = _keywordCtl.text.trim();
      final PagedResult<GoodsListItem> r;
      if (_selectedCategoryId != null) {
        // 选了分类：在分类子树内搜（keyword 可空）。
        r = await ref
            .read(goodsRepositoryProvider)
            .list(
              _selectedCategoryId!,
              page: _page,
              keyword: kw.isEmpty ? null : kw,
              excludeDisabled: true,
              excludeStub: true,
            );
      } else if (kw.isNotEmpty && widget.scope == UtenGoodsPickerScope.all) {
        // 仅 all 范围允许全库搜；sellable/material 必须先选分类，否则会把不该显示的
        // 类目（原材料/成品）混搜出来，回归 ADR-015 当年要消除的老 bug。
        r = await ref
            .read(goodsRepositoryProvider)
            .search(kw, page: _page, excludeDisabled: true, excludeStub: true);
      } else {
        // 既无分类又无关键词：不发请求，提示选择/输入。
        if (!mounted) return;
        setState(() {
          _paged = null;
          _loading = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _paged = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载货品失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 150.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择货品',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: treeWidth,
                child: UtenCategoryTreeView<ProductCategoryNode>(
                  nodes: widget.tree,
                  mode: UtenCategoryTreeMode.single,
                  selectedIds: _selectedCategoryId == null
                      ? const <String>{}
                      : <String>{_selectedCategoryId!},
                  expandOnRowTap: true,
                  initiallyCollapsedNames: const {'未分类'},
                  searchHint: '搜索分类',
                  onToggleSelect: _onCategoryTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
        if (widget.multiSelect || widget.requireConfirm)
          _buildConfirmBar(theme),
      ],
    );
  }

  Widget _buildConfirmBar(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                      widget.multiSelect
                          ? _selected.values.toList()
                          : _selected.values.single,
                    ),
              child: Text(
                !widget.multiSelect || _selected.isEmpty
                    ? '确定'
                    : '确定（${_selected.length}）',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _keywordCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: '搜索编号/名称/型号/规格/客户型号/材质/备注',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: _onKeywordChanged,
          ),
        ),
        Expanded(child: _buildGoodsList(theme)),
        if (_paged != null && _paged!.totalPages > 1) _buildPager(theme),
      ],
    );
  }

  Widget _buildGoodsList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final page = _paged;
    if (page == null) {
      return Center(
        child: Text(
          '请选择左侧分类或输入关键词搜索',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (page.items.isEmpty) {
      return Center(
        child: Text(
          '无匹配货品',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: page.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final g = page.items[i];
        final sub = [
          g.spec,
          g.colorName,
          g.unitName,
        ].where((s) => s != null && s.isNotEmpty).join(' · ');
        final picked = _selected.containsKey(g.id);
        final showPicked =
            (widget.multiSelect || widget.requireConfirm) && picked;
        return ListTile(
          selected: showPicked,
          title: Text(
            '${g.name ?? '—'}'
            '${g.code != null && g.code!.isNotEmpty ? '（${g.code}）' : ''}',
          ),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: const TextStyle(fontSize: 12)),
          trailing: showPicked
              ? Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              : null,
          onTap: () {
            if (widget.multiSelect) {
              setState(() {
                if (_selected.containsKey(g.id)) {
                  _selected.remove(g.id);
                } else {
                  _selected[g.id] = g;
                }
              });
            } else if (widget.requireConfirm) {
              setState(() {
                _selected
                  ..clear()
                  ..[g.id] = g;
              });
            } else {
              Navigator.of(context).pop(g);
            }
          },
        );
      },
    );
  }

  Widget _buildPager(ThemeData theme) {
    final page = _paged!;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: page.page > 1
                ? () {
                    setState(() => _page = page.page - 1);
                    _reloadGoods();
                  }
                : null,
          ),
          Text('${page.page} / ${page.totalPages}'),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: page.page < page.totalPages
                ? () {
                    setState(() => _page = page.page + 1);
                    _reloadGoods();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
