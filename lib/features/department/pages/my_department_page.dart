// MyDepartmentPage - 我的部门（全页面，镜像「部门管理」页布局）
// 文档：docs/03-页面/我的页.md（§我的部门）
//
// 布局复用部门管理页（/department）：
//   expanded：全高分栏 左树(300) | 分隔线 | 右详情
//   compact/medium：组织树进 endDrawer，详情单列（UtenContentContainer 收敛宽度）
// 组件复用：UtenDepartmentTreeView + MasterDetailCard + UtenPersonCard（与部门管理页同款）。
//
// 数据仍走 /api/my-department/**（任意员工可见，无 department:view/employee:view）：
//   部门管理页的 DepartmentOverviewPane 调的是 department:view/employee:view 接口，
//   普通员工 403；故此处复用「布局与组件」但保留 my-department 安全花名册数据源。
// 花名册：负责人/管理人排最前；仅安全联系字段；明确负责人看到“去业务页使用本页权限”的说明，
// 不再在此处维护全目录或中央个人覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../../shared/auth/page_permission_delegation_repository.dart';
import '../../basic_data/widgets/category_tree_search.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../models/department_node.dart';
import '../models/my_department.dart';
import '../providers/my_department_providers.dart';
import '../repositories/my_department_repository.dart';
import '../widgets/uten_department_tree_view.dart';

class MyDepartmentPage extends ConsumerStatefulWidget {
  const MyDepartmentPage({super.key});

  @override
  ConsumerState<MyDepartmentPage> createState() => _MyDepartmentPageState();
}

class _MyDepartmentPageState extends ConsumerState<MyDepartmentPage> {
  String? _selectedId;
  String _searchQuery = '';
  String? _employeeSearchKeyword;
  Set<String>? _visibleFilterIds;
  Set<String> _contentMatchDepartmentIds = {};
  bool _searchLoading = false;
  String? _searchError;
  int _searchRequest = 0;
  bool _acceptPendingSearch = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  void _onSearchInput(String raw) {
    _searchRequest++;
    _acceptPendingSearch = true;
    final tree = ref.read(myDepartmentTreeProvider).valueOrNull;
    if (!mounted || tree == null || tree.isEmpty) return;
    final query = raw.trim();
    setState(() {
      _searchQuery = query;
      _employeeSearchKeyword = null;
      _contentMatchDepartmentIds = {};
      _visibleFilterIds = query.isEmpty ? null : categoryHits(tree, query);
      _searchLoading = query.isNotEmpty;
      _searchError = null;
    });
  }

  void _onSearchChanged(String raw) {
    final query = raw.trim();
    if (!_acceptPendingSearch || query != _searchQuery) return;
    _acceptPendingSearch = false;
    _applyGlobalSearch(query);
  }

  Future<void> _applyGlobalSearch(String rawQuery) async {
    final query = rawQuery.trim();
    final request = ++_searchRequest;
    final tree = ref.read(myDepartmentTreeProvider).valueOrNull;
    if (tree == null || tree.isEmpty) return;

    if (query.isEmpty) {
      setState(() {
        _searchQuery = '';
        _employeeSearchKeyword = null;
        _visibleFilterIds = null;
        _contentMatchDepartmentIds = {};
        _searchLoading = false;
        _searchError = null;
      });
      return;
    }

    final initial = resolveHierarchySearch<DepartmentNode>(
      roots: tree,
      query: query,
    );
    setState(() {
      _searchQuery = query;
      _employeeSearchKeyword = null;
      _visibleFilterIds = initial.visibleIds;
      _contentMatchDepartmentIds = {};
      _searchLoading = true;
      _searchError = null;
      if (initial.selectedId != null) _selectedId = initial.selectedId;
    });

    try {
      // myBranchTree 的根就是服务端已授权的「本人所在大部门」；从该根取花名册
      // 可覆盖整条分支，同时仍严格受 MyDepartmentService 的分支校验约束。
      final roster = await ref
          .read(myDepartmentRepositoryProvider)
          .roster(tree.first.id);
      if (!mounted || request != _searchRequest) return;
      final matched = roster.staff.where((s) => s.matchesSearch(query));
      final resolution = resolveHierarchySearch<DepartmentNode>(
        roots: tree,
        query: query,
        contentCategoryIds: matched.map((s) => s.departmentId),
      );
      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _contentMatchDepartmentIds = resolution.contentCategoryIds;
        _employeeSearchKeyword = resolution.hasContentMatches ? query : null;
        _searchLoading = false;
        _searchError = null;
        if (resolution.selectedId != null) {
          _selectedId = resolution.selectedId;
        }
      });
    } on ApiException catch (e) {
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _searchLoading = false;
        _searchError = e.message;
      });
    } catch (_) {
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _searchLoading = false;
        _searchError = '员工搜索失败，请重试';
      });
    }
  }

  void _refresh() {
    _searchRequest++;
    _acceptPendingSearch = false;
    setState(() {
      _searchQuery = '';
      _employeeSearchKeyword = null;
      _visibleFilterIds = null;
      _contentMatchDepartmentIds = {};
      _searchLoading = false;
      _searchError = null;
    });
    ref.invalidate(myDepartmentTreeProvider);
    ref.invalidate(myDepartmentRosterProvider);
  }

  @override
  Widget build(BuildContext context) {
    final useSplit = context.breakpoint.isExpanded;
    final treeAsync = ref.watch(myDepartmentTreeProvider);
    final tree = treeAsync.valueOrNull ?? const <DepartmentNode>[];
    final selectedId = tree.isNotEmpty ? (_selectedId ?? tree.first.id) : null;

    final Widget body = treeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : '部门信息加载失败',
        actionLabel: '重试',
        onAction: () => ref.invalidate(myDepartmentTreeProvider),
      ),
      data: (_) {
        if (tree.isEmpty) {
          return const UtenEmpty(
            icon: Icons.account_tree_outlined,
            message: '当前员工尚未分配可查看的部门',
          );
        }
        final node = selectedId == null
            ? tree.first
            : (_findNode(tree, selectedId) ?? tree.first);
        final detail = _MyDepartmentDetail(
          node: node,
          employeeFilter: _employeeSearchKeyword ?? '',
        );

        if (useSplit) {
          return UtenSplitView(
            persistenceKey: 'department.mine',
            leading: _buildTree(tree, node.id, onSelect: _selectDepartment),
            trailing: detail,
          );
        }
        // compact/medium：树进抽屉，详情单列收敛宽度。
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: UtenSearchBar(
                key: const ValueKey('my-department-compact-search'),
                initialValue: _searchQuery,
                hint: '搜索部门名称/编号、员工姓名/工号',
                onInputChanged: _onSearchInput,
                onChanged: _onSearchChanged,
              ),
            ),
            Expanded(child: UtenContentContainer(child: detail)),
          ],
        );
      },
    );

    return Scaffold(
      key: _scaffoldKey,
      appBar: UtenAppBar(
        title: '我的部门',
        // go 进入（主 Tab 前缀子路由），栈被替换；返回显式回「我的」页
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.profile),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
          if (!useSplit && selectedId != null)
            IconButton(
              icon: const Icon(Icons.account_tree_rounded),
              tooltip: '部门列表',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
        ],
      ),
      endDrawer: (!useSplit && selectedId != null)
          ? Drawer(
              child: SafeArea(
                child: _buildTree(
                  tree,
                  selectedId,
                  onSelect: (id) {
                    _selectDepartment(id);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }

  void _selectDepartment(String id) {
    _searchRequest++;
    _acceptPendingSearch = false;
    final tree =
        ref.read(myDepartmentTreeProvider).valueOrNull ??
        const <DepartmentNode>[];
    final keepSearch =
        _searchQuery.isNotEmpty && (_visibleFilterIds?.contains(id) ?? false);
    final keepEmployeeKeyword =
        _searchQuery.isNotEmpty &&
        hierarchyBranchContainsAny(tree, id, _contentMatchDepartmentIds);
    setState(() {
      _selectedId = id;
      // 手动选树节点优先于尚未完成的自动定位，避免旧响应稍后把用户跳走。
      _searchLoading = false;
      _searchError = null;
      _employeeSearchKeyword = keepEmployeeKeyword ? _searchQuery : null;
      if (!keepSearch) {
        _searchQuery = '';
        _employeeSearchKeyword = null;
        _visibleFilterIds = null;
        _contentMatchDepartmentIds = {};
        _searchLoading = false;
        _searchError = null;
      }
    });
  }

  /// 组织树（复用 UtenDepartmentTreeView，内置搜索）。onSelect：分栏只切选中；抽屉额外关抽屉。
  Widget _buildTree(
    List<DepartmentNode> tree,
    String selectedId, {
    required ValueChanged<String> onSelect,
  }) {
    return UtenDepartmentTreeView(
      nodes: tree,
      selectedIds: {selectedId},
      onNodeTap: (n) => onSelect(n.id),
      nodeEnabledPredicate: (_) => true,
      expandOnRowTap: true,
      initiallyExpandDepth: 2,
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _searchQuery,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: UtenSearchBar(
          initialValue: _searchQuery,
          hint: '搜索部门名称/编号、员工姓名/工号',
          onInputChanged: _onSearchInput,
          onChanged: _onSearchChanged,
        ),
      ),
    );
  }
}

/// 右侧详情：MasterDetailCard（部门概况，只读）+ 安全花名册（负责人排最前）
/// + 部门负责人页面内委派说明（仅明确负责人显示）。
class _MyDepartmentDetail extends ConsumerWidget {
  const _MyDepartmentDetail({required this.node, required this.employeeFilter});

  final DepartmentNode node;
  final String employeeFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(myDepartmentRosterProvider(node.id));
    final delegationCapability = ref.watch(
      pageDelegationCapabilityProvider('org.employee'),
    );
    final isManaged = delegationCapability.maybeWhen(
      data: (value) => value.canManage,
      orElse: () => false,
    );
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final searching = employeeFilter.trim().isNotEmpty;
    final directCount = async.maybeWhen(
      data: (r) => r.staff.where((s) => s.matchesSearch(employeeFilter)).length,
      orElse: () => null,
    );

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            hPad,
            UtenSpacing.s16,
            hPad,
            UtenSpacing.s12,
          ),
          sliver: SliverToBoxAdapter(
            child: MasterDetailCard(
              title: node.name,
              icon: Icons.account_tree_outlined,
              subtitle:
                  '${node.level} · ${node.code} · ${searching ? '匹配' : '在册'} ${directCount ?? '-'}',
              // 详情卡精简（与分类卡统一）：不再展示统计行与路径行，卡片只留标题；
              // 「我的部门」是只读概览卡，最关键的「在册」人数折进副标题保留。
              stats: const [],
              canEdit: false, // 我的部门只读：编辑/删除/新增子部门按钮不渲染
              onAddChild: () {},
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
        ..._rosterSlivers(async, theme, hPad, ref),
        if (isManaged)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              hPad,
              UtenSpacing.s4,
              hPad,
              UtenSpacing.s16,
            ),
            sliver: const SliverToBoxAdapter(child: _ManagerPermissionPanel()),
          ),
      ],
    );
  }

  List<Widget> _rosterSlivers(
    AsyncValue<MyDepartmentRoster> async,
    ThemeData theme,
    double hPad,
    WidgetRef ref,
  ) {
    EdgeInsets pad({double bottom = UtenSpacing.s16}) =>
        EdgeInsets.fromLTRB(hPad, 0, hPad, bottom);
    return async.when(
      loading: () => [
        SliverPadding(
          padding: pad(),
          sliver: const SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ],
      error: (e, _) => [
        SliverPadding(
          padding: pad(),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: UtenEmpty.error(
                message: e is ApiException ? e.message : '花名册加载失败',
                actionLabel: '重试',
                onAction: () =>
                    ref.invalidate(myDepartmentRosterProvider(node.id)),
              ),
            ),
          ),
        ),
      ],
      data: (roster) {
        final visibleStaff = roster.staff
            .where((s) => s.matchesSearch(employeeFilter))
            .toList();
        // 负责人/管理人排最前（稳定：保留服务端顺序，仅前置 departmentManager）。
        final managers = visibleStaff
            .where((s) => s.departmentManager)
            .toList();
        final others = visibleStaff.where((s) => !s.departmentManager).toList();
        final ordered = [...managers, ...others];
        if (ordered.isEmpty) {
          return [
            SliverPadding(
              padding: pad(),
              sliver: SliverToBoxAdapter(
                child: SizedBox(
                  height: 160,
                  child: UtenEmpty(
                    icon: Icons.people_outline_rounded,
                    message: employeeFilter.trim().isEmpty
                        ? '该部门暂无在册员工'
                        : '该部门未找到匹配「${employeeFilter.trim()}」的员工',
                  ),
                ),
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: pad(bottom: UtenSpacing.s8),
            sliver: SliverToBoxAdapter(
              child: _rosterHeader(
                theme,
                ordered.length,
                searching: employeeFilter.trim().isNotEmpty,
              ),
            ),
          ),
          SliverPadding(
            padding: pad(),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _staffRow(context, theme, ordered[i]),
                childCount: ordered.length,
              ),
            ),
          ),
        ];
      },
    );
  }

  Widget _rosterHeader(ThemeData theme, int count, {required bool searching}) {
    return Row(
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Text(
          '${searching ? '匹配' : '在册'}员工 $count 人',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _staffRow(
    BuildContext context,
    ThemeData theme,
    MyDepartmentStaffRow r,
  ) {
    final parts = <String>[
      if (r.code != null && r.code!.isNotEmpty) r.code!,
      if (r.positionName != null && r.positionName!.isNotEmpty) r.positionName!,
      if (r.officePhone != null && r.officePhone!.isNotEmpty)
        '电话 ${r.officePhone}',
      if (r.email != null && r.email!.isNotEmpty) r.email!,
    ];
    return UtenPersonCard(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      // 花名册只走 my-department 安全字段（普通员工无 employee:view，跳 /employee/:id 会被拦），
      // 点击弹只读联系卡：姓名/岗位/部门/工号/电话/邮箱，不进受限路由。
      onTap: () => _showContactCard(context, r),
      title: r.fullName ?? '—',
      subtitle: parts.isEmpty ? null : parts.join(' · '),
      titleLeading: r.departmentManager
          ? const EmployeeLeadershipBadge(departmentManager: true)
          : null,
      avatarText: r.fullName,
      trailing: r.isSelf ? _selfBadge(theme) : null,
    );
  }

  Widget _selfBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(UtenSpacing.s8),
      ),
      child: Text(
        '我',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 部门负责人的权限面板（非负责人 403 时整体隐藏）。
class _ManagerPermissionPanel extends StatelessWidget {
  const _ManagerPermissionPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.admin_panel_settings_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '成员权限已按业务页面拆分',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '请在对应业务页面右上角点击“本页权限”。系统只列出你当前拥有且允许委派的权限，'
                  '不会改写超级管理员的中央授权，也不会扩大客户、单据等对象数据范围。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

DepartmentNode? _findNode(List<DepartmentNode> nodes, String id) {
  for (final n in nodes) {
    if (n.id == id) return n;
    final hit = _findNode(n.children, id);
    if (hit != null) return hit;
  }
  return null;
}

/// 员工联系卡：窄屏底部弹层、宽屏居中弹窗（与政策详情同款自适应范式）。
/// 只用花名册安全字段，不依赖 employee:view / 不进 /employee/:id，人人可看。
Future<void> _showContactCard(
  BuildContext context,
  MyDepartmentStaffRow r,
) async {
  final content = _ContactCard(row: r);
  if (context.breakpoint.isCompact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => content,
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: content,
        ),
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.row});

  final MyDepartmentStaffRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = (row.fullName ?? '').isEmpty ? '—' : row.fullName!;
    final initial = name.isEmpty ? '?' : name.characters.first;
    final hasCode = (row.code ?? '').isNotEmpty;
    final hasPhone = (row.officePhone ?? '').isNotEmpty;
    final hasEmail = (row.email ?? '').isNotEmpty;
    final subParts = <String>[
      if ((row.positionName ?? '').isNotEmpty) row.positionName!,
      if ((row.departmentName ?? '').isNotEmpty) row.departmentName!,
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s8,
        UtenSpacing.s20,
        UtenSpacing.s20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                  child: Text(initial, style: theme.textTheme.headlineSmall),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    Text(name, style: theme.textTheme.titleLarge),
                    if (row.departmentManager)
                      const EmployeeLeadershipBadge(departmentManager: true),
                    if (row.isSelf) _selfTag(theme),
                  ],
                ),
                if (subParts.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    subParts.join(' · '),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          if (hasCode)
            _ContactLine(
              icon: Icons.badge_outlined,
              label: '工号',
              value: row.code!,
            ),
          if (hasPhone)
            _ContactLine(
              icon: Icons.phone_outlined,
              label: '办公电话',
              value: row.officePhone!,
              onTap: () => _launchUri(context, 'tel:${row.officePhone}'),
            ),
          if (hasEmail)
            _ContactLine(
              icon: Icons.mail_outline_rounded,
              label: '邮箱',
              value: row.email!,
              onTap: () => _launchUri(context, 'mailto:${row.email}'),
            ),
          if (!hasCode && !hasPhone && !hasEmail)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                '暂无其它联系方式',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ContactLine extends StatelessWidget {
  const _ContactLine({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UtenSpacing.s8),
      child: content,
    );
  }
}

Widget _selfTag(ThemeData theme) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: 2,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(UtenSpacing.s8),
    ),
    child: Text(
      '我',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onPrimaryContainer,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

Future<void> _launchUri(BuildContext context, String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || !await launchUrl(parsed)) {
    if (context.mounted) context.appError('无法打开链接');
  }
}
