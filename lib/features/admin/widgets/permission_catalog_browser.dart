import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permission_action_type.dart';
import '../models/admin_models.dart';
import 'perm_catalog_group_section.dart';

enum PermissionCatalogFilter { all, enabled, disabled, changed }

typedef PermissionPredicate = bool Function(AdminPermission permission);
typedef PermissionItemBuilder =
    Widget Function(BuildContext context, AdminPermission permission);

/// 高密度权限目录的统一浏览器（两级：功能模块 → 子类 → 权限项）。
///
/// 权限仍按后端动态目录完整保留。前端按 [PermissionCatalogGroup.module] 聚合成「模块段」，
/// 段内再按 [PermissionCatalogGroup.category]（子类）折叠。管理员可按名称、子类或模块搜索，
/// 或按状态筛选；命中的模块与子类自动展开。批量操作分三档（全部 / 本模块 / 本组），
/// 始终作用于完整集合，不会因当前搜索隐藏了部分权限而产生歧义。
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
    this.enableModuleLabel = '本模块全部授权',
    this.disableModuleLabel = '本模块全部设为未授权',
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

  /// 本模块（一级）整段批量授权/收回；作用于该模块全部权限，复用整组回调。
  final String enableModuleLabel;
  final String disableModuleLabel;

  /// 跨分组「全部授权/全部收回」回调。批量操作始终作用于完整目录
  /// （[groups] 的全部 permissions），不受当前搜索/状态筛选影响。为 null 时按钮不渲染。
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
  final Set<String> _expandedModules = {};
  final Set<String> _expandedCategories = {};
  PermissionCatalogFilter _filter = PermissionCatalogFilter.all;
  PermissionActionType? _actionType;
  String _query = '';

  bool get _hasChangedFilter =>
      widget.isChanged != null && widget.changedFilterLabel != null;

  bool get _isFiltering =>
      _query.trim().isNotEmpty ||
      _filter != PermissionCatalogFilter.all ||
      _actionType != null;

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
  bool _matchesAction(AdminPermission permission) =>
      _actionType == null || permission.actionType == _actionType;

  /// 按输入顺序聚合模块（后端已按 MODULE_ORDER 排序，故输入即模块主序）。
  List<_ModuleGroup> _allModules() {
    final order = <String>[];
    final map = <String, List<PermissionCatalogGroup>>{};
    for (final g in widget.groups) {
      final m = g.module.isEmpty ? '其他' : g.module;
      (map[m] ??= <PermissionCatalogGroup>[]).add(g);
      if (!order.contains(m)) order.add(m);
    }
    return [for (final m in order) _ModuleGroup(m, map[m]!)];
  }

  List<_VisibleModule> _visibleModules() {
    final query = _query.trim().toLowerCase();
    final result = <_VisibleModule>[];
    for (final mod in _allModules()) {
      final moduleMatches = mod.module.toLowerCase().contains(query);
      final fullPerms = <AdminPermission>[];
      final visibleSubcats = <_VisibleSubcat>[];
      for (final g in mod.groups) {
        fullPerms.addAll(g.permissions);
        final catMatches = g.category.toLowerCase().contains(query);
        final visible = g.permissions
            .where((p) {
              if (!_matchesState(p) || !_matchesAction(p)) return false;
              if (query.isEmpty || moduleMatches || catMatches) return true;
              return p.name.toLowerCase().contains(query) ||
                  p.code.toLowerCase().contains(query) ||
                  p.actionType.label.toLowerCase().contains(query) ||
                  (p.description?.toLowerCase().contains(query) ?? false);
            })
            .toList(growable: false);
        if (visible.isNotEmpty) {
          visibleSubcats.add(_VisibleSubcat(g, visible));
        }
      }
      if (visibleSubcats.isNotEmpty) {
        result.add(_VisibleModule(mod.module, fullPerms, visibleSubcats));
      }
    }
    return result;
  }

  bool _isModuleExpanded(String module) =>
      _isFiltering ? true : _expandedModules.contains(module);

  void _setModuleExpanded(String module, bool expanded) {
    if (_isFiltering) return;
    setState(() {
      if (expanded) {
        _expandedModules.add(module);
      } else {
        _expandedModules.remove(module);
      }
    });
  }

  bool _isCategoryExpanded(String category) =>
      _isFiltering ? true : _expandedCategories.contains(category);

  void _setCategoryExpanded(String category, bool expanded) {
    if (_isFiltering) return;
    setState(() {
      if (expanded) {
        _expandedCategories.add(category);
      } else {
        _expandedCategories.remove(category);
      }
    });
  }

  void _setFilter(PermissionCatalogFilter filter) {
    if (_filter == filter) return;
    setState(() => _filter = filter);
  }

  void _setActionType(PermissionActionType? actionType) {
    if (_actionType == actionType) return;
    setState(() => _actionType = actionType);
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = PermissionCatalogFilter.all;
      _actionType = null;
    });
  }

  void _toggleAllModules(List<_VisibleModule> modules) {
    final categories = <String>[];
    final allExpanded = modules.every((m) {
      categories.addAll(m.subcats.map((s) => s.full.category));
      return _expandedModules.contains(m.module);
    });
    setState(() {
      if (allExpanded) {
        _expandedModules.clear();
        _expandedCategories.removeAll(categories);
      } else {
        for (final m in modules) {
          _expandedModules.add(m.module);
        }
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
    final actionTypes = allPermissions.map((p) => p.actionType).toSet().toList()
      ..sort(
        (left, right) => PermissionActionType.values
            .indexOf(left)
            .compareTo(PermissionActionType.values.indexOf(right)),
      );
    final modules = _visibleModules();
    final visibleCount = modules.fold<int>(
      0,
      (sum, m) =>
          sum + m.subcats.fold<int>(0, (s, sc) => s + sc.visible.length),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final search = UtenSearchBar(
              key: const ValueKey('permission-catalog-search'),
              controller: _searchController,
              hint: '搜索权限名称、动作、说明、子类或模块',
              debounce: const Duration(milliseconds: 180),
              onChanged: (value) => setState(() => _query = value),
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
            if (!_isFiltering)
              TextButton.icon(
                key: const ValueKey('permission-toggle-all-groups'),
                onPressed: modules.isEmpty
                    ? null
                    : () => _toggleAllModules(modules),
                icon: Icon(
                  _allModulesExpanded(modules)
                      ? Icons.unfold_less_rounded
                      : Icons.unfold_more_rounded,
                  size: 18,
                ),
                label: Text(_allModulesExpanded(modules) ? '全部折叠' : '全部展开'),
              ),
          ],
        ),
        if (actionTypes.isNotEmpty)
          _actionFilterBar(actionTypes, allPermissions),
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
                    onPressed: () => widget.onEnableAll!(
                      allPermissions
                          .where((permission) => permission.bulkAssignable)
                          .toList(growable: false),
                    ),
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
        if (modules.isEmpty)
          UtenEmpty(
            key: const ValueKey('permission-catalog-empty'),
            icon: Icons.search_off_rounded,
            message: '没有匹配的权限',
            description: '可尝试搜索权限名称、动作或说明，或调整上方状态与动作筛选。',
            actionLabel: '查看全部权限',
            onAction: _resetFilters,
          )
        else
          for (final module in modules) _moduleSection(module),
      ],
    );
  }

  bool _allModulesExpanded(List<_VisibleModule> modules) =>
      modules.isNotEmpty &&
      modules.every((m) => _expandedModules.contains(m.module));

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

  Widget _actionFilterBar(
    List<PermissionActionType> actionTypes,
    List<AdminPermission> allPermissions,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Semantics(
        container: true,
        label: '按动作类型筛选权限',
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '动作类型',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            ChoiceChip(
              key: const ValueKey('permission-action-filter-all'),
              label: Text('全部 ${allPermissions.length}'),
              selected: _actionType == null,
              showCheckmark: false,
              onSelected: (_) => _setActionType(null),
            ),
            for (final type in actionTypes)
              ChoiceChip(
                key: ValueKey(
                  'permission-action-filter-${type.wireValue.toLowerCase()}',
                ),
                label: Text(
                  '${type.label} '
                  '${allPermissions.where((p) => p.actionType == type).length}',
                ),
                selected: _actionType == type,
                showCheckmark: false,
                onSelected: (_) => _setActionType(type),
              ),
          ],
        ),
      ),
    );
  }

  Widget _moduleSection(_VisibleModule module) {
    final moduleTotal = module.fullPerms.length;
    final moduleEnabled = module.fullPerms.where(widget.isEnabled).length;
    final countLabel = _isFiltering
        ? '${module.subcats.fold<int>(0, (s, sc) => s + sc.visible.length)} 项匹配'
        : '$moduleEnabled/$moduleTotal';
    final canBatch =
        widget.onEnableGroup != null || widget.onDisableGroup != null;

    return PermCatalogGroupSection(
      key: ValueKey('permission-module-${module.module}'),
      level: PermCatalogLevel.module,
      title: module.module,
      countLabel: countLabel,
      expanded: _isModuleExpanded(module.module),
      onExpandedChanged: (expanded) =>
          _setModuleExpanded(module.module, expanded),
      trailing: canBatch
          ? PopupMenuButton<_PermissionGroupAction>(
              tooltip: '批量设置${module.module}',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) {
                switch (action) {
                  case _PermissionGroupAction.enable:
                    widget.onEnableGroup?.call(
                      module.fullPerms
                          .where((permission) => permission.bulkAssignable)
                          .toList(growable: false),
                    );
                    break;
                  case _PermissionGroupAction.disable:
                    widget.onDisableGroup?.call(module.fullPerms);
                    break;
                }
              },
              itemBuilder: (context) => [
                if (widget.onEnableGroup != null)
                  PopupMenuItem(
                    value: _PermissionGroupAction.enable,
                    child: Text(widget.enableModuleLabel),
                  ),
                if (widget.onDisableGroup != null)
                  PopupMenuItem(
                    value: _PermissionGroupAction.disable,
                    child: Text(widget.disableModuleLabel),
                  ),
              ],
            )
          : null,
      children: [for (final subcat in module.subcats) _categorySection(subcat)],
    );
  }

  Widget _categorySection(_VisibleSubcat subcat) {
    final group = subcat.full;
    final enabledCount = group.permissions.where(widget.isEnabled).length;
    final countLabel = _isFiltering
        ? '${subcat.visible.length} 项匹配'
        : '$enabledCount/${group.permissions.length}';
    final canBatch =
        widget.onEnableGroup != null || widget.onDisableGroup != null;

    return PermCatalogGroupSection(
      key: ValueKey('permission-category-${group.category}'),
      title: group.category,
      countLabel: countLabel,
      expanded: _isCategoryExpanded(group.category),
      onExpandedChanged: (expanded) =>
          _setCategoryExpanded(group.category, expanded),
      trailing: canBatch
          ? PopupMenuButton<_PermissionGroupAction>(
              tooltip: '批量设置${group.category}',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) {
                switch (action) {
                  case _PermissionGroupAction.enable:
                    widget.onEnableGroup?.call(
                      group.permissions
                          .where((permission) => permission.bulkAssignable)
                          .toList(growable: false),
                    );
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
        for (final permission in subcat.visible)
          KeyedSubtree(
            key: ValueKey('permission-${permission.code}'),
            child: widget.itemBuilder(context, permission),
          ),
      ],
    );
  }
}

class _ModuleGroup {
  const _ModuleGroup(this.module, this.groups);
  final String module;
  final List<PermissionCatalogGroup> groups;
}

class _VisibleSubcat {
  const _VisibleSubcat(this.full, this.visible);
  final PermissionCatalogGroup full;
  final List<AdminPermission> visible;
}

class _VisibleModule {
  const _VisibleModule(this.module, this.fullPerms, this.subcats);
  final String module;
  final List<AdminPermission> fullPerms;
  final List<_VisibleSubcat> subcats;
}

enum _PermissionGroupAction { enable, disable }
