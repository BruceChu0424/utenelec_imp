// 部门管理页（真实后端 + 响应式 + 组件库）
// compact：部门树作为抽屉，点部门看详情/员工（内容套 UtenContentContainer）
// medium/expanded：左侧部门树（DepartmentTree）+ 右侧详情与员工卡片（UtenPersonCard），
//   宽度收敛由 MainShell 统一处理
// 文档：docs/03-页面/部门管理页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';
import '../widgets/department_edit_dialog.dart';
import '../widgets/department_overview_pane.dart';
import '../../basic_data/widgets/category_tree_search.dart';
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

  // 顶部统一搜索（部门名 + 员工姓名/工号）→ 定位部门：visibleFilterIds 驱动树只显示命中部门 + 祖先链。
  Set<String>? _visibleFilterIds;
  String _globalQuery = '';

  // 顶部搜索命中员工时，右侧员工列表同步按该关键词过滤（只显示搜索结果，而非该部门全部）；
  // 清空搜索 / 仅部门名命中 / 手动点树节点时复位为 null。
  String? _employeeSearchKeyword;

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
        // 不预选部门：默认右侧空态，点了部门才加载（省资源）。
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

  // ---- 顶部统一搜索（部门名 + 员工姓名/工号 → 定位部门）----------------------

  void _onGlobalSearch(String q) => _applyGlobalSearch(q.trim());

  Future<void> _applyGlobalSearch(String q) async {
    final tree = _tree;
    if (tree == null || tree.isEmpty) return;
    if (q.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null; // 清空：恢复全树
        _employeeSearchKeyword = null; // 同时解除右侧员工列表的搜索过滤
      });
      return;
    }
    _globalQuery = q;
    // ① 同步：部门名命中（+祖先+子树），先渲染即时结果。
    final catHits = categoryHits(tree, q);
    setState(() => _visibleFilterIds = catHits);
    // ② 异步：员工姓名/工号命中 → 取其 departmentId（+祖先），定位到第一个命中部门。
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .list(search: q, size: 50);
      if (!mounted || _globalQuery != q) return; // 过期结果丢弃
      final ids = <String>{};
      String? first;
      for (final e in result.items) {
        final did = e.departmentId;
        if (did == null || did.isEmpty) continue;
        ids.add(did);
        first ??= did;
      }
      if (ids.isEmpty) {
        final firstDept = shallowestHit(tree, q, catHits);
        setState(() {
          _visibleFilterIds = catHits;
          // 仅部门名命中：定位部门即可，右侧显示该部门全部（部门本身就是搜索结果）。
          _employeeSearchKeyword = null;
          if (firstDept != null && _selectedId != firstDept) {
            _selectedId = firstDept;
          }
        });
        return;
      }
      final merged = <String>{...catHits, ...ids};
      for (final did in ids) {
        addAncestors(tree, did, merged);
      }
      final target = first;
      setState(() {
        _visibleFilterIds = merged;
        // 员工命中：右侧员工列表只显示本次搜索结果（按关键词过滤）。
        _employeeSearchKeyword = q;
        if (_selectedId != target) _selectedId = target;
      });
    } catch (_) {
      // 搜索是辅助功能，失败静默（保留部门名命中结果）。
    }
  }

  Widget _buildGlobalSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: UtenSearchBar(
        hint: '搜索部门/员工姓名/工号', // TODO(l10n): 补 arb
        onChanged: _onGlobalSearch,
      ),
    );
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
        actionsAlignment: MainAxisAlignment.center,
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
    final canAssignManager = kOperationalDepartmentLevels.contains(
      detail.level,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => DepartmentEditDialog(
        managerLoader: canAssignManager
            ? (keyword) => _loadManagerCandidates(detail.id, keyword)
            : null,
        tree: _tree ?? const <DepartmentNode>[],
        editing: detail,
        onSubmit: (r) => _doUpdate(detail, r),
      ),
    );
  }

  Future<bool> _doUpdate(DepartmentInfo detail, DepartmentEditResult r) async {
    if (!_hasPermission(Perm.departmentEdit)) {
      _toastError('无权编辑部门'); // TODO(l10n): 补 arb
      return false;
    }
    try {
      await ref
          .read(departmentRepositoryProvider)
          .update(
            detail.id,
            DepartmentUpdateInput(
              name: r.name,
              // 未移动时不发送 parentId，避免后端把同一父级误判为移动并重算整棵子树。
              parentId: r.parentId == detail.parentId ? null : r.parentId,
              managerId: r.managerId,
              managerSpecified: kOperationalDepartmentLevels.contains(
                detail.level,
              ),
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
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      header: _buildGlobalSearchBox(),
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
      employeeFilter: _employeeSearchKeyword,
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
              // 手动点树节点 = 进入浏览模式：解除搜索过滤，右侧显示该部门全部员工。
              onSelect: (id) => setState(() {
                _selectedId = id;
                _employeeSearchKeyword = null;
              }),
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
                    setState(() {
                      _selectedId = id;
                      _employeeSearchKeyword = null;
                    });
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
