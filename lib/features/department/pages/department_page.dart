// 部门管理页（真实后端 + 响应式 + 组件库）
// compact：部门树作为抽屉，点部门看详情/员工（内容套 UtenContentContainer）
// medium/expanded：左侧部门树（DepartmentTree）+ 右侧详情与员工卡片（UtenPersonCard），
//   宽度收敛由 MainShell 统一处理
// 文档：docs/03-页面/部门管理页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_status_badge.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';
import '../widgets/department_edit_dialog.dart';
import '../widgets/department_overview_pane.dart';
import '../widgets/position_manager_sheet.dart';
import '../widgets/uten_department_tree_view.dart';

class DepartmentPage extends ConsumerStatefulWidget {
  const DepartmentPage({super.key});

  @override
  ConsumerState<DepartmentPage> createState() => _DepartmentPageState();
}

class _DepartmentPageState extends ConsumerState<DepartmentPage> {
  List<DepartmentNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  bool _hasPermission(String permission) =>
      ref.read(currentPermissionsProvider).contains(permission);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _selectedId = _selectedId ?? (tree.isEmpty ? null : tree.first.id);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).departmentLoadFailed;
        _loading = false;
      });
    }
  }

  DepartmentNode? _findById(List<DepartmentNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  /// 新建部门时的常用名称建议。
  static const _departmentSuggestions = [
    '综合办公室',
    '财务室',
    '生产车间',
    '质检部',
    '仓储组',
    '行政组',
  ];

  void _showCreateDialog({DepartmentNode? parent}) {
    if (!_hasPermission(Perm.departmentEdit)) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => DepartmentEditDialog(
        tree: _tree ?? const <DepartmentNode>[],
        initialParent: parent,
        suggestions: _departmentSuggestions,
        onSubmit: _doCreate,
      ),
    );
  }

  Future<bool> _doCreate(DepartmentEditResult r) async {
    final l10n = AppLocalizations.of(context);
    if (!_hasPermission(Perm.departmentEdit)) {
      _toastError('无权新建部门'); // TODO(l10n): 补 arb
      return false;
    }
    try {
      await ref
          .read(departmentRepositoryProvider)
          .create(
            DepartmentSaveInput(
              code: r.code!,
              name: r.name,
              level: r.level,
              parentId: r.parentId,
            ),
          );
      if (!mounted) return false;
      _toastSuccess(l10n.departmentCreated);
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      _toastError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      _toastError(l10n.departmentLoadFailed);
      return false;
    }
  }

  Future<void> _delete(DepartmentNode node) async {
    final l10n = AppLocalizations.of(context);
    if (!_hasPermission(Perm.departmentEdit)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.departmentDialogDeleteTitle),
        content: Text(l10n.departmentDeleteConfirm(node.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.departmentDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(departmentRepositoryProvider).delete(node.id);
      _toastSuccess(l10n.departmentDeleted);
      if (_selectedId == node.id) _selectedId = null;
      await _load();
    } on ApiException catch (e) {
      _toastError(e.message);
    }
  }

  void _toastSuccess(String msg) {
    if (!mounted) return;
    context.appSuccess(msg);
  }

  Future<List<UtenEmployeePickerItem>> _loadManagerCandidates(
    String departmentId,
    String? keyword,
  ) async {
    final result = await ref
        .read(employeeRepositoryProvider)
        .list(
          size: 100,
          search: keyword,
          statuses: const {'active', 'probation', 'onLeave'},
          departmentId: departmentId,
        );
    return result.items
        .map(
          (employee) => UtenEmployeePickerItem(
            id: employee.id,
            name: employee.fullName,
            departmentName: employee.departmentName,
          ),
        )
        .toList();
  }

  void _showEditDialog(DepartmentInfo detail) {
    if (!_hasPermission(Perm.departmentEdit)) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => DepartmentEditDialog(
        managerLoader: (keyword) => _loadManagerCandidates(detail.id, keyword),
        tree: _tree ?? const <DepartmentNode>[],
        editing: detail,
        onSubmit: (r) => _doUpdate(detail.id, r),
      ),
    );
  }

  Future<bool> _doUpdate(String id, DepartmentEditResult r) async {
    if (!_hasPermission(Perm.departmentEdit)) {
      _toastError('无权编辑部门'); // TODO(l10n): 补 arb
      return false;
    }
    try {
      await ref
          .read(departmentRepositoryProvider)
          .update(
            id,
            DepartmentUpdateInput(
              name: r.name,
              parentId: r.parentId,
              managerId: r.managerId,
              managerSpecified: true,
            ),
          );
      if (!mounted) return false;
      _toastSuccess('已保存'); // TODO(l10n): 补 arb
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      _toastError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      _toastError('保存失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
  }

  /// 全站共享组织树（管理模式）：公司根可见、全部节点可点、选中高亮。
  /// onSelect：桌面分栏只切选中；compact 抽屉额外负责关闭抽屉。
  Widget _buildTree(
    AppLocalizations l10n, {
    required void Function(String id) onSelect,
    required bool canEdit,
  }) {
    return UtenDepartmentTreeView(
      nodes: _tree ?? const <DepartmentNode>[],
      showCompanyRoot: true,
      nodeEnabledPredicate: (_) => true,
      selectedIds: {?_selectedId},
      expandOnRowTap: true,
      onNodeTap: (node) => onSelect(node.id),
      trailingBuilder: (node) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.managerName != null && node.managerName!.isNotEmpty)
            Tooltip(
              message: '负责人：${node.managerName}',
              child: Icon(
                Icons.supervisor_account_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          if (canEdit)
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              tooltip: '删除 ${node.name}',
              onPressed: () => _delete(node),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
        ],
      ),
    );
  }

  void _toastError(String msg) {
    if (!mounted) return;
    context.appError(msg);
  }

  /// 详情面板构造（compact 与 medium+ 共用，避免两处重复传参）。
  Widget _buildDetailPane(
    DepartmentNode selected, {
    required bool canEdit,
    required bool canViewEmployees,
    required bool canCreateEmployee,
  }) {
    return DepartmentOverviewPane(
      node: selected,
      canEdit: canEdit,
      canViewEmployees: canViewEmployees,
      canCreateEmployee: canCreateEmployee,
      canManagePermissions:
          ref.read(isSuperAdminProvider) &&
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.authorizationManage),
      onAddChild: () => _showCreateDialog(parent: selected),
      onEdit: (detail) => _showEditDialog(detail),
      onDelete: () => _delete(selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final permissions = ref.watch(currentPermissionsProvider);
    final canEdit = permissions.contains(Perm.departmentEdit);
    final canViewEmployees = permissions.contains(Perm.employeeView);
    final canCreateEmployee =
        permissions.contains(Perm.employeeCreate) &&
        permissions.contains(Perm.employeePiiEdit);
    final tree = _tree ?? const <DepartmentNode>[];
    final selected = _selectedId == null ? null : _findById(tree, _selectedId!);

    final useSplitLayout = bp.isExpanded;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    } else if (tree.isEmpty) {
      // 空树：兜住顶级新建入口（AppBar 已无「+」）。
      body = UtenEmpty(
        icon: Icons.account_tree_outlined,
        message: l10n.departmentEmpty,
        description: l10n.departmentEmptyHint,
        actionLabel: canEdit ? '新建部门' : null, // TODO(l10n): 补 arb
        onAction: canEdit ? () => _showCreateDialog() : null,
      );
    } else if (!useSplitLayout) {
      body = selected == null
          ? UtenEmpty(
              icon: Icons.account_tree_outlined,
              message: l10n.departmentEmpty,
              description: l10n.departmentEmptyHint,
            )
          // 非宽屏使用单列详情，组织树放入抽屉，避免 medium 宽度下双栏拥挤。
          : UtenContentContainer(
              child: _buildDetailPane(
                selected,
                canEdit: canEdit,
                canViewEmployees: canViewEmployees,
                canCreateEmployee: canCreateEmployee,
              ),
            );
    } else {
      body = Row(
        children: [
          SizedBox(
            width: 300,
            child: _buildTree(
              l10n,
              canEdit: canEdit,
              onSelect: (id) => setState(() => _selectedId = id),
            ),
          ),
          Container(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: selected == null
                ? Center(child: Text(l10n.departmentEmptySelect))
                : _buildDetailPane(
                    selected,
                    canEdit: canEdit,
                    canViewEmployees: canViewEmployees,
                    canCreateEmployee: canCreateEmployee,
                  ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.departmentTitle,
        showBackButton: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: l10n.departmentTooltipRefresh,
            onPressed: _load,
          ),
          if (!useSplitLayout)
            Builder(
              builder: (scaffoldCtx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: l10n.departmentTooltipTree,
                onPressed: () => Scaffold.of(scaffoldCtx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: !useSplitLayout
          ? Drawer(
              child: SafeArea(
                child: _buildTree(
                  l10n,
                  canEdit: canEdit,
                  onSelect: (id) {
                    setState(() => _selectedId = id);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }
}

/// 部门详情 + 该部门（含子部门）员工卡片。
// ignore: unused_element
class _DetailPane extends StatefulWidget {
  const _DetailPane({
    required this.ref,
    required this.nodeId,
    required this.node,
    required this.canEdit,
    required this.canViewEmployees,
    required this.canCreateEmployee,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final WidgetRef ref;
  final String nodeId;

  /// 当前选中节点（岗位管理 sheet 需要 id/name）。
  final DepartmentNode node;
  final bool canEdit;
  final bool canViewEmployees;
  final bool canCreateEmployee;
  final VoidCallback onAddChild;
  final void Function(DepartmentInfo detail) onEdit;
  final VoidCallback onDelete;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  DepartmentInfo? _info;
  List<EmployeeSummary> _employees = const [];
  bool _loading = true;
  String? _error;
  String _keyword = ''; // 员工搜索（姓名/工号），切换部门时重置

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
    } else if (!old.canViewEmployees && widget.canViewEmployees) {
      _loadEmployees();
    } else if (old.canViewEmployees && !widget.canViewEmployees) {
      setState(() => _employees = const []);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _keyword = ''; // 切换部门重置搜索
    });
    try {
      final dept = widget.ref.read(departmentRepositoryProvider);
      final info = await dept.detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
      if (widget.canViewEmployees) await _loadEmployees();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).departmentLoadFailed;
        _loading = false;
      });
    }
  }

  /// 拉员工列表（当前部门子树 + [_keyword] 搜索）。切换部门与搜索都走这里。
  Future<void> _loadEmployees() async {
    try {
      final emp = widget.ref.read(employeeRepositoryProvider);
      final page = await emp.list(
        departmentId: widget.nodeId,
        includeSubtree: true,
        size: 200,
        search: _keyword.trim().isEmpty ? null : _keyword,
      );
      if (!mounted) return;
      setState(() => _employees = page.items);
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('搜索员工失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  void _onSearchChanged(String kw) {
    setState(() => _keyword = kw);
    _loadEmployees();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    }
    final info = _info;
    if (info == null) return const SizedBox.shrink();
    final canAddStaff = kSelectableDepartmentLevels.contains(info.level);
    // compact：容器 gutter 已提供水平留白；medium+：详情面板在树右侧，需自带水平内边距
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        hPad,
        UtenSpacing.s16,
        hPad,
        UtenSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
            child: MasterDetailCard(
              title: info.name,
              icon: Icons.account_tree_outlined,
              subtitle: l10n.departmentLevelAndCode(info.level, info.code),
              stats: [
                MasterDetailStat(
                  l10n.departmentStatEmployees,
                  '${info.employeeCount}',
                ),
                MasterDetailStat(
                  l10n.departmentStatChildren,
                  '${info.childCount}',
                ),
                MasterDetailStat(l10n.departmentStatManager, info.managerName),
                MasterDetailStat(l10n.departmentStatParent, info.parentName),
              ],
              path: info.path.isEmpty ? null : info.path,
              canEdit: widget.canEdit,
              addChildLabel: '新增子部门', // TODO(l10n): 补 arb
              onAddChild: widget.onAddChild,
              onEdit: () {
                final d = _info;
                if (d != null) widget.onEdit(d);
              },
              onDelete: widget.onDelete,
              extraActions: canAddStaff
                  ? [
                      MasterDetailCardAction(
                        icon: Icons.badge_outlined,
                        label: '岗位管理', // TODO(l10n): 补 arb
                        onPressed: () =>
                            showPositionManagerSheet(context, widget.node),
                      ),
                    ]
                  : const [],
            ),
          ),
          if (widget.canViewEmployees) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(
                    Icons.people_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    l10n.departmentEmployeesHeader(_employees.length),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenSearchBar(
                      hint: '搜索员工（姓名/工号）', // TODO(l10n): 补 arb
                      initialValue: _keyword,
                      onChanged: _onSearchChanged,
                    ),
                  ),
                  if (canAddStaff && widget.canCreateEmployee) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.add_rounded,
                      onPressed: () => context.push(
                        '/employee/onboarding?departmentId=${info.id}',
                      ),
                      child: const Text('添加员工'), // TODO(l10n): 补 arb
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _employees.isEmpty
                  ? Center(
                      child: UtenEmpty(
                        icon: Icons.people_outline_rounded,
                        message: l10n.departmentEmployeesEmpty,
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                      children: [
                        for (final e in _employees)
                          UtenPersonCard(
                            margin: const EdgeInsets.only(
                              bottom: UtenSpacing.s8,
                            ),
                            title: e.fullName,
                            subtitle:
                                '${e.code} · ${e.departmentName ?? ''} · ${e.positionName ?? ''}',
                            avatarText: e.fullName,
                            trailing: EmployeeStatusBadge(status: e.status),
                            onTap: () => context.push('/employee/${e.id}'),
                          ),
                      ],
                    ),
            ),
          ] else
            const Expanded(
              child: UtenEmpty(
                icon: Icons.lock_outline_rounded,
                message: '无员工档案查看权限', // TODO(l10n): 补 arb
              ),
            ),
        ],
      ),
    );
  }
}
