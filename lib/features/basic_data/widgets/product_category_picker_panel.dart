// 货品分类侧滑选择面板——查询页「货品分类」筛选的统一入口（2026-09-11）。
//
// 取代 ProductCategoryDropdown（层级摊平的 DropdownButtonFormField）：用户口径
// 「点击货品分类应该显示侧边滑窗，跟货品资料里面的一样，不是下拉框」。面板内容
// 直接复用货品资料页那棵树（UtenCategoryTreeView<ProductCategoryNode>：可展开
// 折叠、搜索、命中路径自动展开、选中高亮），外壳复用 showUtenAdaptivePanel
//（宽屏右侧 420 滑入 / 窄屏 85% 底部弹层），与货品/客户/供应商选择器同范式。
//
// 交互契约：
// - 顶部固定「全部」行 = 清空筛选（当前无选中时打勾）；
// - 点分类行或「全部」只更新暂存选择，底部「确定」才返回；取消/关闭放弃暂存；
// - 有子类的行左侧 chevron 单独负责展开/收起，行点击只选择；
// - 零货品分类整支隐藏（goodsCount == 0；null = 后端未给计数，不隐藏），
//   与旧下拉同口径——空分类只是噪音。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/product_category_node.dart';
import 'uten_category_tree_view.dart';

/// 面板选择结果。
///
/// 返回 null（面板 pop 无值）= 用户取消，调用方不应改动现有筛选；
/// [id] 为 null 的结果 = 显式选了「全部」，调用方应清空筛选。
class ProductCategoryPickResult {
  const ProductCategoryPickResult({this.id, this.name});

  /// 选中的分类 id；null = 全部（不过滤）。
  final String? id;

  /// 选中的分类名；「全部」时为 null。
  final String? name;

  bool get isAll => id == null;
}

/// 按 goodsCount 剪枝：零货品分类整支去掉（计数是子树口径，父类无货子类必无货）。
/// goodsCount == null（后端未给计数）一律保留。
List<ProductCategoryNode> pruneCategoriesWithoutGoods(
  List<ProductCategoryNode> nodes,
) => [
  for (final node in nodes)
    if (node.goodsCount == null || node.goodsCount! > 0)
      ProductCategoryNode(
        id: node.id,
        code: node.code,
        name: node.name,
        level: node.level,
        parentId: node.parentId,
        sortOrder: node.sortOrder,
        legacyId: node.legacyId,
        remark: node.remark,
        codePrefix: node.codePrefix,
        systemManaged: node.systemManaged,
        goodsCount: node.goodsCount,
        children: pruneCategoriesWithoutGoods(node.children),
      ),
];

/// 在分类树里按 id 找名称（字段只存 id 的页面用它回显筛选字段文案）。
String? findCategoryName(List<ProductCategoryNode> nodes, String? id) {
  if (id == null || id.isEmpty) return null;
  for (final node in nodes) {
    if (node.id == id) return node.name;
    final hit = findCategoryName(node.children, id);
    if (hit != null) return hit;
  }
  return null;
}

/// 拉开货品分类侧滑面板。返回 null = 取消；返回 [ProductCategoryPickResult.isAll]
/// = 选了「全部」。
Future<ProductCategoryPickResult?> showUtenProductCategoryPickerPanel(
  BuildContext context, {
  required List<ProductCategoryNode> tree,
  String? selectedId,
  String title = '选择货品分类', // TODO(l10n): 补 arb
  String subtitle = '选父类 = 该分类子树聚合', // TODO(l10n): 补 arb
  String allLabel = '全部', // TODO(l10n): 补 arb
  bool hideEmptyCategories = true,
  Widget Function(BuildContext context, Widget child)? scopeBuilder,
}) {
  // 单根提升：整库只有一个「货品资料」包装根时不占一层，直接列其子类
  //（与货品选择滑窗同口径，2026-09-24）。
  final selectableTree = hideEmptyCategories
      ? pruneCategoriesWithoutGoods(tree)
      : tree;
  final visibleTree = hoistSingleRootTree(selectableTree);
  // 提升只隐藏包装根的层级，不使其已有筛选失效；被剪枝/删除的初值不可确认。
  final initialName = findCategoryName(selectableTree, selectedId);
  final initialSelection = selectedId == null || selectedId.isEmpty
      ? const ProductCategoryPickResult()
      : initialName == null
      ? null
      : ProductCategoryPickResult(id: selectedId, name: initialName);
  return showUtenAdaptivePanel<ProductCategoryPickResult>(
    context: context,
    widthFraction: UtenPanelWidth.form,
    builder: (panelContext) {
      final sheet = _ProductCategoryPickerSheet(
        tree: visibleTree,
        initialSelection: initialSelection,
        title: title,
        subtitle: subtitle,
        allLabel: allLabel,
      );
      return scopeBuilder?.call(panelContext, sheet) ?? sheet;
    },
  );
}

class _ProductCategoryPickerSheet extends StatefulWidget {
  const _ProductCategoryPickerSheet({
    required this.tree,
    required this.title,
    required this.subtitle,
    required this.allLabel,
    this.initialSelection,
  });

  final List<ProductCategoryNode> tree;
  final ProductCategoryPickResult? initialSelection;
  final String title;
  final String subtitle;
  final String allLabel;

  @override
  State<_ProductCategoryPickerSheet> createState() =>
      _ProductCategoryPickerSheetState();
}

class _ProductCategoryPickerSheetState
    extends State<_ProductCategoryPickerSheet> {
  ProductCategoryPickResult? _pendingSelection;

  @override
  void initState() {
    super.initState();
    _pendingSelection = widget.initialSelection;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allSelected = _pendingSelection?.isAll ?? false;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭', // TODO(l10n): 补 arb
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 「全部」同样先暂存，确定后才清空调用方的筛选。
            ListTile(
              key: const Key('category-picker-all'),
              selected: allSelected,
              selectedTileColor: theme.colorScheme.primaryContainer,
              leading: Icon(
                Icons.all_inbox_rounded,
                color: theme.colorScheme.primary,
              ),
              title: Text(widget.allLabel),
              trailing: allSelected
                  ? Icon(
                      Icons.check_circle_rounded,
                      color: theme.colorScheme.primary,
                    )
                  : null,
              onTap: () => setState(
                () => _pendingSelection = const ProductCategoryPickResult(),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: widget.tree.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s24),
                          child: Text(
                            '暂无可选分类', // TODO(l10n): 补 arb
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : UtenCategoryTreeView<ProductCategoryNode>(
                        key: const Key('category-picker-tree'),
                        nodes: widget.tree,
                        mode: UtenCategoryTreeMode.single,
                        selectedIds: {?_pendingSelection?.id},
                        // 行点击只暂存选择；展开/收起交给左侧 chevron。
                        // 左树默认全部收起（2026-09-24 用户口径，与货品选择滑窗同款）。
                        initiallyExpandDepth: 0,
                        initiallyCollapsedNames: const {'未分类'},
                        searchFieldKey: const Key('category-picker-search'),
                        searchHint: '搜索分类名称 / 编号', // TODO(l10n): 补 arb
                        // 无缩进层级色（与货品选择滑窗左树同款，2026-09-24）。
                        flatLevelColors: true,
                        trailingBuilder: (node) => node.goodsCount == null
                            ? null
                            : Text(
                                '${node.goodsCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                        onToggleSelect: (node) => setState(
                          () => _pendingSelection = ProductCategoryPickResult(
                            id: node.id,
                            name: node.name,
                          ),
                        ),
                      ),
              ),
            ),
            UtenPickerConfirmBar(
              selectedCount: _pendingSelection == null ? 0 : 1,
              selectedLabel: allSelected
                  ? widget.allLabel
                  : _pendingSelection?.name,
              onConfirm: () => Navigator.of(context).pop(_pendingSelection),
            ),
          ],
        ),
      ),
    );
  }
}
