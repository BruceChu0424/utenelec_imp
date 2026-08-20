// UtenClientPicker - 客户选择器（单据表头选客户用，问题 #15）
//
// 触发：函数式 showUtenClientPicker(context, ref) → 返回 ClientListItem?。
// 形态仿 showUtenGoodsPicker（左客户分类树 + 右客户列表，搜索+分页），compact 底部抽屉 /
// medium+ 右侧滑入 720 宽面板。数据来自 clientRepositoryProvider，后端 list()/search()
// 已按 client:view:all 权限点做行级过滤（仅本人客户 / 授权可看指定业务员 / 全部），
// 前端不用重复实现过滤——这正是本组件要替换掉的旧版 UtenDropdownField 平铺下拉缺的能力：
// 旧下拉走 salesMasterNameServiceProvider 的 /clients/dict（同样已过滤，但只有 id/name，
// 没有联系人/地址等客户资料，也不能按分类浏览）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../models/client_node.dart';
import '../models/product_category_node.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import 'category_tree_search.dart';
import 'uten_category_tree_view.dart';

/// 老库遗留的财务占位客户（非真实客户），列表/搜索一律排除——与
/// SalesMasterNameService._loadClients 的 selectable 口径一致。
/// 禁用（status=禁用）客户同样不进选择器：单据不能再选它开新单；
/// 已删除（软删）后端已过滤不下发。
bool _clientSelectable(ClientListItem c) =>
    !(c.code ?? '').startsWith('LEGACY-FIN-CL-') && c.status != '禁用';

/// 弹出客户选择器，返回所选客户；取消返回 null。
Future<ClientListItem?> showUtenClientPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  List<ProductCategoryNode> tree;
  try {
    tree = await ref.read(clientCategoryRepositoryProvider).tree();
  } catch (_) {
    if (context.mounted) context.appError('客户分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _ClientPickerSheet(tree: tree);
  return showUtenAdaptivePanel<ClientListItem>(
    context: context,
    drawerWidth: 720,
    builder: (_) => sheet,
  );
}

class _ClientPickerSheet extends ConsumerStatefulWidget {
  const _ClientPickerSheet({required this.tree});
  final List<ProductCategoryNode> tree;

  @override
  ConsumerState<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends ConsumerState<_ClientPickerSheet> {
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
  List<ClientListItem>? _items;
  int _totalPages = 1;
  String? _globalItemsQuery;
  List<ClientListItem> _globalItems = const [];
  bool _loading = false;
  String? _error;

  /// 已点选（高亮）的客户；点底部「确定」才 pop 返回，取消/关闭则放弃（二次操作契约）。
  ClientListItem? _picked;

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
    // 用户继续输入时立即让正在飞行的旧请求失效，避免 300ms 防抖期间旧结果回写。
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
          .read(clientRepositoryProvider)
          .list(
            categoryId,
            page: _page,
            keyword: _categoryContentKeyword,
            excludeLegacyFinanceStub: true,
          );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _items = r.items.where(_clientSelectable).toList();
        _totalPages = r.totalPages < 1 ? 1 : r.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '加载客户失败，请稍后重试';
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
      final repo = ref.read(clientRepositoryProvider);
      List<ClientListItem> allItems;
      if (_globalItemsQuery == query) {
        allItems = _globalItems;
      } else {
        final byId = <String, ClientListItem>{};
        var backendPage = 1;
        var backendTotalPages = 1;
        while (backendPage <= backendTotalPages) {
          final result = await repo.search(
            query,
            page: backendPage,
            size: 100,
            excludeLegacyFinanceStub: true,
          );
          if (!mounted ||
              requestVersion != _requestVersion ||
              query != _globalQuery ||
              requestedPage != _page) {
            return;
          }
          for (final client in result.items) {
            if (_clientSelectable(client)) {
              byId.putIfAbsent(client.id, () => client);
            }
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
        contentCategoryIds: allItems.map((client) => client.categoryId),
      );

      if (allItems.isEmpty && allowCategoryFallback && requestedPage == 1) {
        final categoryId = resolution.selectedId;
        if (categoryId != null) {
          final categoryPage = await repo.list(
            categoryId,
            excludeLegacyFinanceStub: true,
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
            _items = categoryPage.items.where(_clientSelectable).toList();
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
          _error = '搜索客户失败，请稍后重试';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 176.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择客户',
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
          selectedLabel: _picked == null ? null : _clientLabel(_picked!),
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }

  String _clientLabel(ClientListItem c) =>
      '${c.name ?? c.fullName ?? '—'}'
      '${c.code != null && c.code!.isNotEmpty ? '（${c.code}）' : ''}';

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
        key: const Key('uten-client-picker-search'),
        controller: _keywordCtl,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          hintText: '搜索分类/客户',
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
          '未找到匹配客户',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final c = items[i];
        final sub = [
          c.linkman,
          c.mobile,
          c.address,
        ].where((s) => s != null && s.isNotEmpty).join(' · ');
        final picked = _picked?.id == c.id;
        return ListTile(
          selected: picked,
          title: Text(_clientLabel(c)),
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
          onTap: () => setState(() => _picked = c),
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

/// 只读展示 + 点击打开 [showUtenClientPicker] 的表单字段（单据表头「客户」用，问题 #15）。
/// 只提交客户 id，展示名由本组件自行持有（同 packaging_picker_field.dart 的
/// 静态 ctx.initialValue 注释：宿主表单每次 onChanged 后都用同一份静态初值重建）。
class ClientPickerField extends StatefulWidget {
  const ClientPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.label = '客户',
    this.required = false,
    this.errorText,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值（客户 id 字符串或 null）。
  final void Function(String? id) onChanged;

  /// 打开客户选择器，取消返回 null。
  final Future<ClientListItem?> Function() onPick;

  final String label;
  final bool required;
  final String? errorText;

  @override
  State<ClientPickerField> createState() => _ClientPickerFieldState();
}

class _ClientPickerFieldState extends State<ClientPickerField> {
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
  void didUpdateWidget(ClientPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上游引入等场景会用新 id/name 重建本字段（表头未选客户时以上游单据客户回填）：
    // 静态初值变化时同步一次，避免仍显示旧的（空）值。
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

  void _set(ClientListItem? item) {
    setState(() {
      _id = item?.id;
      _ctl.text = item?.name ?? item?.fullName ?? '';
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredEmpty =
        widget.required && _id == null && widget.errorText == null;
    return TextField(
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
          hintText: '点击选择客户',
          errorText: widget.errorText,
          prefixIcon: const Icon(Icons.storefront_outlined),
          suffixIcon: _id != null
              ? IconButton(
                  tooltip: '清除选择',
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () => _set(null),
                )
              : Icon(
                  Icons.unfold_more_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
        theme,
        requiredEmpty: requiredEmpty,
      ),
      onTap: () async {
        final item = await widget.onPick();
        if (item != null) _set(item);
      },
    );
  }
}
