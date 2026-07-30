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

/// 弹出货品选择器，返回所选货品（完整 GoodsListItem）；取消返回 null。
Future<GoodsListItem?> showUtenGoodsPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  List<ProductCategoryNode> tree;
  try {
    final raw = await ref.read(productCategoryRepositoryProvider).tree();
    tree = _filterExcludedTree(raw);
  } catch (_) {
    if (context.mounted) context.appError('货品分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _GoodsPickerSheet(tree: tree);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<GoodsListItem>(
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
  return showGeneralDialog<GoodsListItem>(
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
  const _GoodsPickerSheet({required this.tree});
  final List<ProductCategoryNode> tree;

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

  @override
  void initState() {
    super.initState();
    // 默认选中第一个根分类并加载其货品（避免打开时空白）。
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reloadGoods());
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
            );
      } else if (kw.isNotEmpty) {
        // 没选分类但有关键词：全库搜。
        r = await ref.read(goodsRepositoryProvider).search(kw, page: _page);
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
                  searchHint: '搜索分类',
                  onToggleSelect: _onCategoryTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
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
              hintText: '搜索货品编号/名称/型号/规格',
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
        return ListTile(
          title: Text(
            '${g.name ?? '—'}'
            '${g.code != null && g.code!.isNotEmpty ? '（${g.code}）' : ''}',
          ),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: const TextStyle(fontSize: 12)),
          onTap: () => Navigator.of(context).pop(g),
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
