// UtenSupplierPicker - 供应商选择器（单据选商用：采购/委外表头 + 明细行级供应商）。
//
// 形态仿 showUtenClientPicker（销售订货单「客户」同款）：compact 底部抽屉 /
// medium+ 右侧滑入 720 宽面板；左侧供应商分类树 + 右侧供应商列表（搜索+分页），
// 布局与基础资料-供应商资料一致。数据请求 selectableOnly：仅「使用」状态的供应商
// 进入分页（禁用商不显示，total 与 items 是同一数据库谓词下的权威结果）。
// 头部带「添加供应商」（supplier:create 权限）：快捷新建入主档后自动选中该新商。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/product_category_node.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import 'category_tree_search.dart';
import 'supplier_quick_create_sheet.dart';
import 'uten_category_tree_view.dart';

/// 弹出供应商选择器，返回所选供应商；取消返回 null。
Future<SupplierListItem?> showUtenSupplierPicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择供应商',
}) async {
  List<ProductCategoryNode> tree;
  try {
    tree = await ref.read(supplierCategoryRepositoryProvider).tree();
  } catch (_) {
    if (context.mounted) context.appError('供应商分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  return showUtenAdaptivePanel<SupplierListItem>(
    context: context,
    drawerWidth: 720,
    builder: (_) => _SupplierPickerSheet(tree: tree, title: title),
  );
}

class _SupplierPickerSheet extends ConsumerStatefulWidget {
  const _SupplierPickerSheet({required this.tree, required this.title});
  final List<ProductCategoryNode> tree;
  final String title;

  @override
  ConsumerState<_SupplierPickerSheet> createState() =>
      _SupplierPickerSheetState();
}

class _SupplierPickerSheetState extends ConsumerState<_SupplierPickerSheet> {
  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  Timer? _debounce;
  String _globalQuery = '';
  Set<String>? _visibleFilterIds;
  Set<String> _contentMatchCategoryIds = {};
  bool _searchLocationLoading = false;
  String? _searchLocationError;
  bool _showingGlobalResults = false;
  String? _categoryContentKeyword;
  int _requestVersion = 0;
  int _page = 1;
  List<SupplierListItem>? _items;
  int _totalPages = 1;
  String? _globalItemsQuery;
  List<SupplierListItem> _globalItems = const [];
  bool _loading = false;
  String? _error;

  /// 已点选（高亮）的供应商；点底部「确定」才 pop 返回，取消/关闭则放弃（二次操作契约）。
  SupplierListItem? _picked;

  @override
  void initState() {
    super.initState();
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
      _reloadCategory();
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    _debounce?.cancel();
    _requestVersion++;
    final keepKeyword =
        _globalQuery.isNotEmpty &&
        hierarchyBranchContainsAny(
          widget.tree,
          node.id,
          _contentMatchCategoryIds,
        );
    setState(() {
      _selectedCategoryId = node.id;
      _categoryContentKeyword = keepKeyword ? _globalQuery : null;
      _showingGlobalResults = false;
      _page = 1;
    });
    _reloadCategory();
  }

  void _onKeywordChanged(String v) {
    _debounce?.cancel();
    _requestVersion++;
    final query = v.trim();
    _globalItemsQuery = null;
    _globalItems = const [];
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _applyGlobalSearch(query);
    });
  }

  Future<void> _applyGlobalSearch(String query) async {
    if (!mounted) return;
    if (query.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null;
        _contentMatchCategoryIds = {};
        _globalItemsQuery = null;
        _globalItems = const [];
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = false;
        _categoryContentKeyword = null;
        _selectedCategoryId ??= widget.tree.isEmpty
            ? null
            : widget.tree.first.id;
        _page = 1;
      });
      await _reloadCategory();
      return;
    }

    setState(() {
      _globalQuery = query;
      _visibleFilterIds = categoryHits(widget.tree, query);
      _contentMatchCategoryIds = {};
      _globalItemsQuery = null;
      _globalItems = const [];
      _searchLocationLoading = true;
      _searchLocationError = null;
      _showingGlobalResults = true;
      _categoryContentKeyword = null;
      _page = 1;
    });
    await _reloadGlobalSearch(allowCategoryFallback: true);
  }

  Future<void> _reloadCategory() async {
    final categoryId = _selectedCategoryId;
    final requestVersion = ++_requestVersion;
    if (categoryId == null) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _totalPages = 1;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(supplierRepositoryProvider)
          .list(
            categoryId,
            page: _page,
            keyword: _categoryContentKeyword,
            selectableOnly: true,
          );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _items = r.items;
        _totalPages = r.totalPages < 1 ? 1 : r.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '加载供应商失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _reloadGlobalSearch({
    required bool allowCategoryFallback,
  }) async {
    final query = _globalQuery;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(supplierRepositoryProvider);
      List<SupplierListItem> allItems;
      if (_globalItemsQuery == query) {
        allItems = _globalItems;
      } else {
        final byId = <String, SupplierListItem>{};
        var backendPage = 1;
        var backendTotalPages = 1;
        while (backendPage <= backendTotalPages) {
          final result = await repo.search(
            query,
            page: backendPage,
            size: 100,
            selectableOnly: true,
          );
          if (!mounted ||
              requestVersion != _requestVersion ||
              query != _globalQuery ||
              requestedPage != _page) {
            return;
          }
          for (final supplier in result.items) {
            byId.putIfAbsent(supplier.id, () => supplier);
          }
          if (result.totalPages > backendTotalPages) {
            backendTotalPages = result.totalPages;
          }
          backendPage++;
        }
        allItems = byId.values.toList(growable: false);
      }
      final resolution = resolveHierarchySearch(
        roots: widget.tree,
        query: query,
        contentCategoryIds: allItems.map((supplier) => supplier.categoryId),
      );

      if (allItems.isEmpty && allowCategoryFallback && requestedPage == 1) {
        final categoryId = resolution.selectedId;
        if (categoryId != null) {
          final categoryPage = await repo.list(
            categoryId,
            selectableOnly: true,
          );
          if (!mounted ||
              requestVersion != _requestVersion ||
              query != _globalQuery ||
              requestedPage != _page) {
            return;
          }
          setState(() {
            _selectedCategoryId = categoryId;
            _visibleFilterIds = resolution.visibleIds;
            _contentMatchCategoryIds = {};
            _globalItemsQuery = query;
            _globalItems = const [];
            _searchLocationLoading = false;
            _searchLocationError = null;
            _showingGlobalResults = false;
            _categoryContentKeyword = null;
            _items = categoryPage.items;
            _totalPages = categoryPage.totalPages < 1
                ? 1
                : categoryPage.totalPages;
            _loading = false;
          });
          return;
        }
      }

      const displaySize = 100;
      final totalPages = allItems.isEmpty
          ? 1
          : (allItems.length + displaySize - 1) ~/ displaySize;
      final safePage = requestedPage.clamp(1, totalPages);
      final start = (safePage - 1) * displaySize;
      final end = (start + displaySize).clamp(0, allItems.length);
      setState(() {
        _selectedCategoryId = resolution.selectedId;
        _visibleFilterIds = resolution.visibleIds;
        _contentMatchCategoryIds = resolution.contentCategoryIds;
        _globalItemsQuery = query;
        _globalItems = allItems;
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = true;
        _page = safePage;
        _items = allItems.sublist(start, end);
        _totalPages = totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        if (_items == null || _loading) {
          _error = '搜索供应商失败，请稍后重试';
        } else {
          _searchLocationError = '完整分类定位失败，请稍后重试';
        }
        _loading = false;
        _searchLocationLoading = false;
      });
    }
  }

  void _reloadCurrentPage() {
    if (_globalQuery.isNotEmpty && _showingGlobalResults) {
      _reloadGlobalSearch(allowCategoryFallback: false);
    } else {
      _reloadCategory();
    }
  }

  /// 面板内「添加供应商」（supplier:create）：快捷新建入主档 → 刷新供应商字典
  /// （表单下拉名解析）→ 直接选中新商（调用方拿到返回值即默认选中）。
  Future<void> _addSupplier() async {
    final created = await showSupplierQuickCreateSheet(context, ref);
    if (created == null || !mounted) return;
    await ref.read(masterNameServiceProvider).reloadSuppliers();
    if (!mounted) return;
    setState(() {
      _picked = SupplierListItem(
        id: created.id,
        name: created.name,
        description: created.description,
        place: created.place,
        linkman: created.linkman,
        mobile: created.mobile,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.supplierCreate);
    final treeWidth = context.breakpoint.isCompact ? 176.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (canAdd)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    onPressed: _addSupplier,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加供应商'),
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
                      : {_selectedCategoryId!},
                  expandOnRowTap: true,
                  showSearch: false,
                  visibleFilterIds: _visibleFilterIds,
                  externalSearchQuery: _globalQuery,
                  externalSearchLoading: _searchLocationLoading,
                  externalSearchError: _searchLocationError,
                  header: _buildUnifiedSearch(),
                  onToggleSelect: _onCategoryTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
        UtenPickerConfirmBar(
          selectedCount: _picked == null ? 0 : 1,
          selectedLabel: _picked == null ? null : _supplierLabel(_picked!),
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }

  String _supplierLabel(SupplierListItem s) =>
      (s.name?.isNotEmpty == true ? s.name! : (s.description ?? '—'));

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Expanded(child: _buildList(theme)),
        if ((_items?.isNotEmpty ?? false) && _totalPages > 1)
          _buildPager(theme),
      ],
    );
  }

  Widget _buildUnifiedSearch() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.breakpoint.isCompact ? 8 : 16,
        8,
        context.breakpoint.isCompact ? 8 : 16,
        8,
      ),
      child: TextField(
        controller: _keywordCtl,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          hintText: '搜索分类/供应商',
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onChanged: _onKeywordChanged,
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    final items = _items;
    if (items == null || items.isEmpty) {
      return Center(
        child: Text(
          '未找到匹配供应商',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final s = items[i];
        final sub = [
          s.place,
          s.linkman,
          s.mobile,
        ].where((v) => v != null && v.isNotEmpty).join(' · ');
        final picked = _picked?.id == s.id;
        return ListTile(
          selected: picked,
          title: Text(_supplierLabel(s)),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: Theme.of(ctx).textTheme.bodySmall),
          trailing: picked
              ? Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              : null,
          onTap: () => setState(() => _picked = s),
        );
      },
    );
  }

  Widget _buildPager(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _page > 1
                ? () {
                    setState(() => _page -= 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
          Text('$_page / $_totalPages'),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _page < _totalPages
                ? () {
                    setState(() => _page += 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

/// 只读展示 + 点击打开 [showUtenSupplierPicker] 的表单字段（单据表头「供应商/委外商」用，
/// 与销售订货单「客户」ClientPickerField 同款交互）。只提交供应商 id；展示名由调用方
/// 经 [initialName] 提供（含「（已禁用）」标注等口径），程序化改值时同步显示。
class SupplierPickerField extends StatefulWidget {
  const SupplierPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.label = '供应商',
    this.required = false,
    this.enabled = true,
    this.errorMessage,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值（供应商 id 或 null=清除）。
  final void Function(String? id) onChanged;

  /// 打开供应商选择器（返回 SupplierListItem?；取消 null）。
  final Future<SupplierListItem?> Function() onPick;

  final String label;
  final bool required;
  final bool enabled;
  final String? errorMessage;

  @override
  State<SupplierPickerField> createState() => _SupplierPickerFieldState();
}

class _SupplierPickerFieldState extends State<SupplierPickerField> {
  late final TextEditingController _ctl;
  String? _id;

  @override
  void initState() {
    super.initState();
    _id = (widget.initialId == null || widget.initialId!.isEmpty)
        ? null
        : widget.initialId;
    _ctl = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void didUpdateWidget(SupplierPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上游引入/到货预填等场景会程序化改值：静态初值变化时同步显示。
    if (widget.initialId != oldWidget.initialId ||
        widget.initialName != oldWidget.initialName) {
      _id = (widget.initialId == null || widget.initialId!.isEmpty)
          ? null
          : widget.initialId;
      _ctl.text = widget.initialName ?? '';
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(SupplierListItem? item) {
    setState(() {
      _id = item?.id;
      _ctl.text = item == null ? '' : _supplierFieldLabel(item);
    });
    widget.onChanged(_id);
  }

  static String _supplierFieldLabel(SupplierListItem s) =>
      (s.name?.isNotEmpty == true ? s.name! : (s.description ?? ''));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredEmpty =
        widget.required && _id == null && widget.errorMessage == null;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.6,
      child: TextField(
        controller: _ctl,
        readOnly: true,
        decoration: applyRequiredEmpty(
          InputDecoration(
            label: requiredLabel(
              widget.label,
              theme,
              required: widget.required,
              base: theme.inputDecorationTheme.labelStyle,
            ),
            hintText: '点击选择${widget.label}',
            error: widget.errorMessage == null
                ? null
                : UtenFieldMessage.error(widget.errorMessage!),
            prefixIcon: const Icon(Icons.local_shipping_outlined),
            suffixIcon: _id != null
                ? IconButton(
                    tooltip: '清除选择',
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: widget.enabled ? () => _set(null) : null,
                  )
                : Icon(
                    Icons.unfold_more_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
          ),
          theme,
          requiredEmpty: requiredEmpty,
        ),
        onTap: widget.enabled
            ? () async {
                final item = await widget.onPick();
                if (item != null) _set(item);
              }
            : null,
      ),
    );
  }
}
