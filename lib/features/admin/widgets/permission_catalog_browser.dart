import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/admin_models.dart';
import 'perm_catalog_group_section.dart';

enum PermissionCatalogFilter { all, enabled, disabled, changed }

typedef PermissionPredicate = bool Function(AdminPermission permission);
typedef PermissionItemBuilder =
    Widget Function(BuildContext context, AdminPermission permission);

/// 高密度权限目录的统一浏览器。
///
/// 权限仍按后端动态目录完整保留，但默认只展示分组摘要。管理员可以按名称、编码或
/// 分组搜索，也可以按状态筛选；命中的分组自动展开。批量操作始终作用于完整分组，
/// 不会因当前搜索隐藏了部分权限而产生歧义。
class PermissionCatalogBrowser extends StatefulWidget {
  const PermissionCatalogBrowser({
    super.key,
    required this.groups,
    required this.isEnabled,
    required this.itemBuilder,
    this.isChanged,
    this.enabledFilterLabel = '已授权',
    this.disabledFilterLabel = '未授权',
    this.changedFilterLabel,
    this.onEnableGroup,
    this.onDisableGroup,
    this.enableGroupLabel = '本组全部授权',
    this.disableGroupLabel = '本组全部设为未授权',
    this.onEnableAll,
    this.onDisableAll,
    this.enableAllLabel = '全部授权',
    this.disableAllLabel = '全部收回',
  });

  final List<PermissionCatalogGroup> groups;
  final PermissionPredicate isEnabled;
  final PermissionPredicate? isChanged;
  final PermissionItemBuilder itemBuilder;
  final String enabledFilterLabel;
  final String disabledFilterLabel;
  final String? changedFilterLabel;
  final ValueChanged<List<AdminPermission>>? onEnableGroup;
  final ValueChanged<List<AdminPermission>>? onDisableGroup;
  final String enableGroupLabel;
  final String disableGroupLabel;

  /// 跨分组「全部授权/全部收回」回调。批量操作始终作用于完整目录
  /// （[groups] 的全部 permissions），不受当前搜索/状态筛选影响——与
  /// [onEnableGroup] 的整组批量原则一致。为 null 时对应按钮不渲染。
  final ValueChanged<List<AdminPermission>>? onEnableAll;
  final ValueChanged<List<AdminPermission>>? onDisableAll;
  final String enableAllLabel;
  final String disableAllLabel;

  @override
  State<PermissionCatalogBrowser> createState() =>
      _PermissionCatalogBrowserState();
}

class _PermissionCatalogBrowserState extends State<PermissionCatalogBrowser> {
  final _searchController = TextEditingController();
  final Set<String> _expandedCategories = {};
  final Set<String> _collapsedWhileFiltering = {};
  PermissionCatalogFilter _filter = PermissionCatalogFilter.all;
  String _query = '';

  bool get _hasChangedFilter =>
      widget.isChanged != null && widget.changedFilterLabel != null;

  bool get _isFiltering =>
      _query.trim().isNotEmpty || _filter != PermissionCatalogFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesState(AdminPermission permission) => switch (_filter) {
    PermissionCatalogFilter.all => true,
    PermissionCatalogFilter.enabled => widget.isEnabled(permission),
    PermissionCatalogFilter.disabled => !widget.isEnabled(permission),
    PermissionCatalogFilter.changed =>
      widget.isChanged?.call(permission) ?? false,
  };

  List<_VisiblePermissionGroup> _visibleGroups() {
    final query = _query.trim().toLowerCase();
    final visible = <_VisiblePermissionGroup>[];
    for (final group in widget.groups) {
      final groupMatches = group.category.toLowerCase().contains(query);
      final permissions = group.permissions
          .where((permission) {
            if (!_matchesState(permission)) return false;
            if (query.isEmpty || groupMatches) return true;
            return permission.name.toLowerCase().contains(query) ||
                permission.code.toLowerCase().contains(query);
          })
          .toList(growable: false);
      if (permissions.isNotEmpty) {
        visible.add(_VisiblePermissionGroup(group, permissions));
      }
    }
    return visible;
  }

  bool _isExpanded(String category) {
    if (_isFiltering) {
      return !_collapsedWhileFiltering.contains(category);
    }
    return _expandedCategories.contains(category);
  }

  void _setExpanded(String category, bool expanded) {
    setState(() {
      final target = _isFiltering
          ? _collapsedWhileFiltering
          : _expandedCategories;
      if (_isFiltering) {
        expanded ? target.remove(category) : target.add(category);
      } else {
        expanded ? target.add(category) : target.remove(category);
      }
    });
  }

  void _setFilter(PermissionCatalogFilter filter) {
    if (_filter == filter) return;
    setState(() {
      _filter = filter;
      _collapsedWhileFiltering.clear();
    });
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = PermissionCatalogFilter.all;
      _collapsedWhileFiltering.clear();
    });
  }

  void _toggleAllGroups(List<_VisiblePermissionGroup> groups) {
    final categories = groups.map((group) => group.group.category).toSet();
    final allExpanded = categories.every(_isExpanded);
    setState(() {
      if (_isFiltering) {
        if (allExpanded) {
          _collapsedWhileFiltering.addAll(categories);
        } else {
          _collapsedWhileFiltering.removeAll(categories);
        }
      } else if (allExpanded) {
        _expandedCategories.removeAll(categories);
      } else {
        _expandedCategories.addAll(categories);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allPermissions = [
      for (final group in widget.groups) ...group.permissions,
    ];
    final total = allPermissions.length;
    final enabledCount = allPermissions.where(widget.isEnabled).length;
    final changedCount = widget.isChanged == null
        ? 0
        : allPermissions.where(widget.isChanged!).length;
    final groups = _visibleGroups();
    final visibleCount = groups.fold<int>(
      0,
      (sum, group) => sum + group.permissions.length,
    );
    final allExpanded =
        groups.isNotEmpty &&
        groups.every((group) => _isExpanded(group.group.category));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final search = UtenSearchBar(
              key: const ValueKey('permission-catalog-search'),
              controller: _searchController,
              hint: '搜索权限名称、代码或分组',
              debounce: const Duration(milliseconds: 180),
              onChanged: (value) => setState(() {
                _query = value;
                _collapsedWhileFiltering.clear();
              }),
            );
            final summary = Text(
              '显示 $visibleCount / $total 项 · '
              '${widget.enabledFilterLabel} $enabledCount 项',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
            if (constraints.maxWidth >= 680) {
              return Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: UtenSpacing.s12),
                  summary,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                search,
                const SizedBox(height: UtenSpacing.s8),
                summary,
              ],
            );
          },
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  _filterChip(
                    key: const ValueKey('permission-filter-all'),
                    label: '全部 $total',
                    value: PermissionCatalogFilter.all,
                  ),
                  _filterChip(
                    key: const ValueKey('permission-filter-enabled'),
                    label: '${widget.enabledFilterLabel} $enabledCount',
                    value: PermissionCatalogFilter.enabled,
                  ),
                  _filterChip(
                    key: const ValueKey('permission-filter-disabled'),
                    label:
                        '${widget.disabledFilterLabel} ${total - enabledCount}',
                    value: PermissionCatalogFilter.disabled,
                  ),
                  if (_hasChangedFilter)
                    _filterChip(
                      key: const ValueKey('permission-filter-changed'),
                      label: '${widget.changedFilterLabel} $changedCount',
                      value: PermissionCatalogFilter.changed,
                    ),
                ],
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            TextButton.icon(
              key: const ValueKey('permission-toggle-all-groups'),
              onPressed: groups.isEmpty ? null : () => _toggleAllGroups(groups),
              icon: Icon(
                allExpanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 18,
              ),
              label: Text(allExpanded ? '全部折叠' : '全部展开'),
            ),
          ],
        ),
        if ((widget.onEnableAll != null || widget.onDisableAll != null) &&
            allPermissions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              children: [
                if (widget.onEnableAll != null)
                  FilledButton.tonalIcon(
                    onPressed: () => widget.onEnableAll!(allPermissions),
                    icon: const Icon(Icons.done_all_rounded, size: 18),
                    label: Text(widget.enableAllLabel),
                  ),
                if (widget.onDisableAll != null)
                  TextButton.icon(
                    onPressed: () => widget.onDisableAll!(allPermissions),
                    icon: const Icon(Icons.remove_done_outlined, size: 18),
                    label: Text(widget.disableAllLabel),
                  ),
              ],
            ),
          ),
        const SizedBox(height: UtenSpacing.s12),
        if (groups.isEmpty)
          UtenEmpty(
            key: const ValueKey('permission-catalog-empty'),
            icon: Icons.search_off_rounded,
            message: '没有匹配的权限',
            description: '可尝试搜索权限名称、代码或分组，或切换上方状态筛选。',
            actionLabel: '查看全部权限',
            onAction: _resetFilters,
          )
        else
          for (final visibleGroup in groups) _groupSection(visibleGroup),
      ],
    );
  }

  Widget _filterChip({
    required Key key,
    required String label,
    required PermissionCatalogFilter value,
  }) {
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: _filter == value,
      showCheckmark: false,
      onSelected: (_) => _setFilter(value),
    );
  }

  Widget _groupSection(_VisiblePermissionGroup visibleGroup) {
    final group = visibleGroup.group;
    final enabledCount = group.permissions.where(widget.isEnabled).length;
    final countLabel = _isFiltering
        ? '${visibleGroup.permissions.length} 项匹配'
        : '$enabledCount/${group.permissions.length}';
    final canBatch =
        widget.onEnableGroup != null || widget.onDisableGroup != null;

    return PermCatalogGroupSection(
      key: ValueKey('permission-group-${group.category}'),
      title: group.category,
      countLabel: countLabel,
      expanded: _isExpanded(group.category),
      onExpandedChanged: (expanded) => _setExpanded(group.category, expanded),
      trailing: canBatch
          ? PopupMenuButton<_PermissionGroupAction>(
              tooltip: '批量设置${group.category}',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) {
                switch (action) {
                  case _PermissionGroupAction.enable:
                    widget.onEnableGroup?.call(group.permissions);
                    break;
                  case _PermissionGroupAction.disable:
                    widget.onDisableGroup?.call(group.permissions);
                    break;
                }
              },
              itemBuilder: (context) => [
                if (widget.onEnableGroup != null)
                  PopupMenuItem(
                    value: _PermissionGroupAction.enable,
                    child: Text(widget.enableGroupLabel),
                  ),
                if (widget.onDisableGroup != null)
                  PopupMenuItem(
                    value: _PermissionGroupAction.disable,
                    child: Text(widget.disableGroupLabel),
                  ),
              ],
            )
          : null,
      children: [
        for (final permission in visibleGroup.permissions)
          KeyedSubtree(
            key: ValueKey('permission-${permission.code}'),
            child: widget.itemBuilder(context, permission),
          ),
      ],
    );
  }
}

class _VisiblePermissionGroup {
  const _VisiblePermissionGroup(this.group, this.permissions);

  final PermissionCatalogGroup group;
  final List<AdminPermission> permissions;
}

enum _PermissionGroupAction { enable, disable }
