// AdminPermissionsPage - 账号支持与权限管理。
//
// account:support 可执行账号锁定/启停/重置密码。
// authorization:manage + superAdmin 才显示个人/部门授权与数据范围。
// 三种授权模式共用固定位置的分类导航与左右分栏，切换时保留未保存修改。
// 按员工：主从布局（expanded 左列表右详情；compact 列表 → 详情带返回）。
// 按部门：单选部门 + 从完整权限目录勾选权限点（见 widgets/admin_department_perm_view.dart）。
// 全员基础包：每个在职员工默认拥有的码(见 widgets/admin_baseline_perm_view.dart)。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 路由守卫与工作台显隐共用 permission_by_path.dart。
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:flutter/material.dart';
import '../../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../widgets/admin_permission_templates.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_load_more_boundary.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/formatters/employee_display.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';
import '../widgets/admin_baseline_perm_view.dart';
import '../widgets/admin_department_perm_view.dart';
import '../widgets/admin_permission_transfer_actions.dart';
import '../widgets/admin_permission_workspace.dart';
import '../widgets/admin_user_detail_panel.dart';
import '../widgets/provision_account_dialog.dart';
import '../widgets/permission_batch_dialog.dart';

class AdminPermissionsPage extends ConsumerStatefulWidget {
  const AdminPermissionsPage({
    super.key,
    this.initialEmployeeId,
    this.initialDepartmentId,
  });

  final String? initialEmployeeId;
  final String? initialDepartmentId;

  @override
  ConsumerState<AdminPermissionsPage> createState() =>
      _AdminPermissionsPageState();
}

class _AdminPermissionsPageState extends ConsumerState<AdminPermissionsPage> {
  /// 0=按员工，1=按部门，2=全员基础包，3=权限模板。
  int _segment = 0;
  bool _templatesVisited = false;
  String _employeeSearch = '';
  final _pendingPermissionChanges = <int, bool>{};

  /// 各分区的离开守卫（三选一：保存并离开/不保存/继续编辑），返回 true 才放行。
  final _leaveGuards = <int, Future<bool> Function()>{};
  bool _allowRoutePop = false;
  final _workspaceKey = GlobalKey();
  final _leadingWidth = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _leadingWidth.dispose();
    super.dispose();
  }

  void _permissionPendingChanged(int segment, bool pending) {
    if (_pendingPermissionChanges[segment] == pending || !mounted) return;
    setState(() => _pendingPermissionChanges[segment] = pending);
  }

  void _leaveGuardChanged(int segment, Future<bool> Function()? guard) {
    if (guard == null) {
      _leaveGuards.remove(segment);
    } else {
      _leaveGuards[segment] = guard;
    }
  }

  bool get _anyPending => _pendingPermissionChanges.values.any((p) => p);

  /// 离开页面前：逐个有草稿的分区走三选一，全部放行才允许返回。
  Future<void> _guardRoutePop() async {
    for (final segment in _pendingPermissionChanges.keys.toList()) {
      if (_pendingPermissionChanges[segment] != true) continue;
      final guard = _leaveGuards[segment];
      if (guard == null) continue;
      final allowed = await guard();
      if (!mounted || !allowed) return;
    }
    if (!mounted) return;
    setState(() => _allowRoutePop = true);
    Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialDepartmentId != null) _segment = 1;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous != null && previous != next) {
        setState(() {
          _employeeSearch = '';
          _pendingPermissionChanges.clear();
        });
      }
    });
    final permissions = ref.watch(currentPermissionsProvider);
    final canManageAuthorization =
        ref.watch(isSuperAdminProvider) &&
        permissions.contains(Perm.authorizationManage);
    final segment = canManageAuthorization ? _segment : 0;

    final categoryNavigation = canManageAuthorization
        ? Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: UtenSegmentedFilter<int>(
              key: const ValueKey('admin-permission-modules'),
              segments: [
                const UtenSegment(value: 0, label: '按员工'),
                const UtenSegment(value: 1, label: '按部门'),
                const UtenSegment(value: 2, label: '全员基础包'),
                UtenSegment(
                  value: 3,
                  label: AppLocalizations.of(context).permissionTemplateTab,
                ),
              ],
              selected: segment,
              onChanged: (value) => setState(() {
                _segment = value;
                if (value == 3) _templatesVisited = true;
              }),
            ),
          )
        : const SizedBox.shrink();
    final accountListHeader = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSearchBar(
            key: ValueKey((
              'admin-account-list-search',
              ref.watch(sensitiveReadBoundaryProvider),
            )),
            hint: '搜索姓名 / 工号 / 登录账号',
            initialValue: _employeeSearch,
            onChanged: (value) {
              final query = value.trim();
              if (query != _employeeSearch) {
                setState(() => _employeeSearch = query);
              }
            },
          ),
        ),
      ],
    );
    Widget body = KeyedSubtree(
      key: _workspaceKey,
      child: AdminPermissionWorkspaceScope(
        leadingWidth: _leadingWidth,
        child: IndexedStack(
          key: ValueKey(ref.watch(sensitiveReadBoundaryProvider)),
          index: segment,
          children: [
            _EmployeePermTab(
              canManageAuthorization: canManageAuthorization,
              initialEmployeeId: widget.initialEmployeeId,
              search: _employeeSearch,
              leadingHeader: accountListHeader,
              navigation: categoryNavigation,
              onPermissionDirtyChanged: (pending) =>
                  _permissionPendingChanged(0, pending),
              onLeaveGuardChanged: (guard) => _leaveGuardChanged(0, guard),
            ),
            if (canManageAuthorization)
              AdminDepartmentPermView(
                initialDepartmentId: widget.initialDepartmentId,
                leadingHeader: categoryNavigation,
                onPermissionDirtyChanged: (pending) =>
                    _permissionPendingChanged(1, pending),
                onLeaveGuardChanged: (guard) => _leaveGuardChanged(1, guard),
              ),
            if (canManageAuthorization)
              AdminBaselinePermView(
                leadingHeader: categoryNavigation,
                onPermissionDirtyChanged: (pending) =>
                    _permissionPendingChanged(2, pending),
                onLeaveGuardChanged: (guard) => _leaveGuardChanged(2, guard),
              ),
            if (canManageAuthorization)
              _templatesVisited
                  ? AdminPermissionTemplatesView(
                      navigation: categoryNavigation,
                      onPermissionDirtyChanged: (pending) =>
                          _permissionPendingChanged(3, pending),
                      onLeaveGuardChanged: (guard) =>
                          _leaveGuardChanged(3, guard),
                    )
                  : const SizedBox.shrink(),
          ],
        ),
      ),
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    } else {
      body = UtenPageEdgePadding(child: body);
    }

    // 统一顶栏：左上角全局返回键（UtenBackButton），AppBar 自带顶部安全区
    return PopScope<void>(
      canPop: _allowRoutePop || !_anyPending,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_allowRoutePop) _guardRoutePop();
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: canManageAuthorization ? '账号与权限管理' : '账号支持',
          showBackButton: true,
          actions: [
            if (canManageAuthorization)
              AdminPermissionArchiveActions(
                importEnabled: !_pendingPermissionChanges.values.any(
                  (pending) => pending,
                ),
              ),
          ],
        ),
        body: body,
      ),
    );
  }
}

/// 按员工：账号列表（搜索/状态筛选/加载更多）+ 详情面板（主从布局）。
class _EmployeePermTab extends ConsumerStatefulWidget {
  const _EmployeePermTab({
    required this.canManageAuthorization,
    required this.search,
    required this.leadingHeader,
    required this.navigation,
    required this.onPermissionDirtyChanged,
    this.onLeaveGuardChanged,
    this.initialEmployeeId,
  });

  final bool canManageAuthorization;
  final String search;
  final Widget leadingHeader;
  final Widget navigation;
  final ValueChanged<bool> onPermissionDirtyChanged;
  final ValueChanged<Future<bool> Function()?>? onLeaveGuardChanged;

  @override
  ConsumerState<_EmployeePermTab> createState() => _EmployeePermTabState();
  final String? initialEmployeeId;
}

class _EmployeePermTabState extends ConsumerState<_EmployeePermTab> {
  static const _statusKeys = ['active', 'locked', 'disabled'];

  String _search = '';
  String? _statusFilter; // null = 全部
  final List<AdminUserSummary> _items = [];
  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _automaticLoadFailed = false;
  String? _error;
  int _requestEpoch = 0;

  AdminUserSummary? _selected;
  bool _multiSelection = false;
  bool _batchBusy = false;
  final _batchUsers = <String, AdminUserSummary>{};
  bool _showDetail = false; // compact 下是否进入详情视图
  final _detailPanelKey = GlobalKey<AdminUserDetailPanelState>();

  @override
  void initState() {
    super.initState();
    _search = widget.search;
    widget.onLeaveGuardChanged?.call(() async {
      final panel = _detailPanelKey.currentState;
      return panel == null ? true : panel.confirmLeaveDrafts();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    widget.onLeaveGuardChanged?.call(null);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _EmployeePermTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.search != widget.search) {
      _search = widget.search;
      _reload();
    }
  }

  Future<void> _initialize() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    AdminUserSummary? initialTarget;
    String? initialError;
    final employeeId = widget.initialEmployeeId;
    if (employeeId != null && employeeId.isNotEmpty) {
      try {
        initialTarget = await ref
            .read(adminRepositoryProvider)
            .userByEmployeeId(employeeId);
      } on ApiException catch (e) {
        initialError = e.message;
      } catch (_) {
        initialError = '无法定位该员工的登录账号';
      }
    }
    await _reload();
    if (!mounted || ref.read(sensitiveReadBoundaryProvider) != boundary) return;
    if (initialTarget != null) {
      setState(() {
        _selected = initialTarget;
        _showDetail = true;
      });
    } else if (initialError != null) {
      context.appError(initialError);
    }
  }

  Future<void> _reload() async {
    final requestEpoch = ++_requestEpoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _loading = true;
      _loadingMore = false;
      _automaticLoadFailed = false;
      _error = null;
    });
    _page = 1;
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .listUsers(
            search: _search.isEmpty ? null : _search,
            status: _statusFilter,
          );
      if (!mounted ||
          requestEpoch != _requestEpoch ||
          ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      final selected = _selected;
      AdminUserSummary? refreshed;
      if (selected != null) {
        for (final row in r.items) {
          if (row.id == selected.id) refreshed = row;
        }
      }
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _totalPages = r.totalPages;
        _loading = false;
        if (selected != null &&
            _selected?.id == selected.id &&
            refreshed != null) {
          _selected = refreshed;
        }
      });
      if (_selected == null) widget.onPermissionDirtyChanged(false);
      // 选中账号可能在别的页/筛选外：补查其最新档案放后台，不阻塞列表落地
      // （此前串行等这趟往返，刷新耗时直接翻倍）。
      if (selected != null && refreshed == null) {
        final targetPage = await ref
            .read(adminRepositoryProvider)
            .listUsers(search: selected.loginAccount);
        if (!mounted ||
            requestEpoch != _requestEpoch ||
            ref.read(sensitiveReadBoundaryProvider) != boundary ||
            _selected?.id != selected.id) {
          return;
        }
        AdminUserSummary? found;
        for (final row in targetPage.items) {
          if (row.id == selected.id) found = row;
        }
        setState(() {
          _selected = found;
        });
      }
    } on ApiException catch (e) {
      if (!mounted ||
          requestEpoch != _requestEpoch ||
          ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          requestEpoch != _requestEpoch ||
          ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      setState(() {
        _error = '加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore({bool automatic = false}) async {
    if (_loading ||
        _loadingMore ||
        _page >= _totalPages ||
        (automatic && _automaticLoadFailed)) {
      return;
    }
    final requestEpoch = _requestEpoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final nextPage = _page + 1;
    setState(() {
      _loadingMore = true;
      _automaticLoadFailed = false;
    });
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .listUsers(
            page: nextPage,
            search: _search.isEmpty ? null : _search,
            status: _statusFilter,
          );
      if (!mounted ||
          requestEpoch != _requestEpoch ||
          ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      setState(() {
        _items.addAll(r.items);
        _page = nextPage;
        _totalPages = r.totalPages;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted ||
          requestEpoch != _requestEpoch ||
          ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      setState(() {
        _loadingMore = false;
        // Preserve the visible manual action as the retry surface; repeated
        // near-edge movement must not spin on the same failed page.
        _automaticLoadFailed = true;
      });
    }
  }

  void _changeStatusFilter(String? status) {
    if (status == _statusFilter) return;
    setState(() => _statusFilter = status);
    _reload();
  }

  /// 切员工/返回列表前三选一（保存并离开/不保存/继续编辑），交给详情面板统一处理。
  Future<bool> _confirmDiscardPermissionChanges() async {
    final panel = _detailPanelKey.currentState;
    return panel == null ? true : await panel.confirmLeaveDrafts();
  }

  Future<void> _onUserTap(AdminUserSummary u) async {
    if (u.id == _selected?.id) {
      if (!_showDetail) setState(() => _showDetail = true);
      return;
    }
    if (!await _confirmDiscardPermissionChanges()) return;
    setState(() {
      _selected = u;
      _showDetail = true;
    });
    widget.onPermissionDirtyChanged(false);
  }

  Future<void> _onBack() async {
    if (!await _confirmDiscardPermissionChanges()) return;
    if (!mounted) return;
    setState(() {
      _showDetail = false;
    });
    widget.onPermissionDirtyChanged(false);
  }

  /// 详情面板完成账号操作后回调：刷新列表并同步选中项。
  void _onAccountChanged() => _reload();

  @override
  Widget build(BuildContext context) {
    ref.listen(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous != null && previous != next) {
        final boundaryRequest = ++_requestEpoch;
        setState(() {
          _items.clear();
          _selected = null;
          _batchUsers.clear();
          _multiSelection = false;
          _batchBusy = false;
          _showDetail = false;
          _loading = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _requestEpoch == boundaryRequest &&
              ref.read(sensitiveReadBoundaryProvider) == next) {
            _reload();
          }
        });
      }
    });
    return AdminPermissionWorkspace(
      navigation: widget.navigation,
      leading: _listColumn(),
      trailing: _detailArea(showBack: false),
      compact: _multiSelection && _showDetail
          ? _batchSummary(showBack: true)
          : _showDetail && _selected != null
          ? _detailArea(showBack: true)
          : _listColumn(),
    );
  }

  bool _canSelectUser(AdminUserSummary user) =>
      user.authorizationGrantAllowed &&
      user.id != ref.read(sessionProvider).user?.id;

  Future<void> _toggleMulti() async {
    if (_batchBusy || !await _confirmDiscardPermissionChanges() || !mounted) {
      return;
    }
    setState(() {
      _multiSelection = !_multiSelection;
      _batchUsers.clear();
      _showDetail = false;
    });
  }

  void _toggleBatchUser(AdminUserSummary user) {
    if (!_canSelectUser(user) || _batchBusy) return;
    if (!_batchUsers.containsKey(user.id) && _batchUsers.length >= 500) {
      context.appWarning('一次最多选择 500 人');
      return;
    }
    setState(() {
      _batchUsers.containsKey(user.id)
          ? _batchUsers.remove(user.id)
          : _batchUsers[user.id] = user;
    });
  }

  Future<void> _applyBatch(bool templateMode) async {
    if (_batchUsers.isEmpty || _batchBusy) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final ids = _batchUsers.keys.toList(growable: false);
    setState(() => _batchBusy = true);
    try {
      final result = await showPermissionBatchDialog(
        context,
        templateMode: templateMode,
        userIds: ids,
        targetLabel: '已选 ${ids.length} 名员工（包含筛选外的已选员工）',
      );
      if (!mounted || boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      if (result == true) {
        context.appSuccess('已更新 ${ids.length} 名员工的权限');
        _onAccountChanged();
      }
    } finally {
      if (mounted && boundary == ref.read(sensitiveReadBoundaryProvider)) {
        setState(() => _batchBusy = false);
      }
    }
  }

  Widget _batchSummary({bool showBack = false}) => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _batchBusy
                  ? null
                  : () => setState(() => _showDetail = false),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回员工列表'),
            ),
          ),
        UtenSectionHeader(
          title: '已选 ${_batchUsers.length} 名员工',
          info: '选择会跨搜索和加载更多保留；“选择已加载”只选择当前已加载的可授权员工。',
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _batchUsers.isNotEmpty && !_batchBusy
                  ? () => _applyBatch(true)
                  : null,
              icon: const Icon(Icons.link_rounded, size: 18),
              label: const Text('应用模板'),
            ),
            OutlinedButton.icon(
              onPressed: _batchUsers.isNotEmpty && !_batchBusy
                  ? () => _applyBatch(false)
                  : null,
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text('批量设置权限'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final user in _batchUsers.values)
                ListTile(
                  dense: true,
                  title: Text(user.employeeName ?? user.loginAccount),
                  subtitle: Text(user.loginAccount),
                  trailing: IconButton(
                    tooltip: '移出选择',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _batchBusy
                        ? null
                        : () => setState(() => _batchUsers.remove(user.id)),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _detailArea({required bool showBack}) {
    if (_multiSelection) return _batchSummary();
    final theme = Theme.of(context);
    final u = _selected;
    if (u == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_search_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '从左侧选择一名员工查看权限详情',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return AdminUserDetailPanel(
      key: _detailPanelKey,
      user: u,
      canManageAuthorization: widget.canManageAuthorization,
      showBack: showBack,
      onBack: _onBack,
      onAccountChanged: _onAccountChanged,
      onProvisionAccount: () =>
          showProvisionAccountDialog(context, onProvisioned: _reload),
      onPermissionDirtyChanged: widget.onPermissionDirtyChanged,
    );
  }

  Widget _listColumn() {
    // 与人事-员工详情页同权限级：account:support 可补开登录账号。
    final canSupportAccount = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.accountSupport);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.leadingHeader,
        if (widget.canManageAuthorization)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('permission-employee-multi-select'),
                onPressed: _batchBusy ? null : _toggleMulti,
                icon: Icon(
                  _multiSelection
                      ? Icons.close_rounded
                      : Icons.checklist_rounded,
                  size: 18,
                ),
                label: Text(_multiSelection ? '结束多选' : '多选'),
              ),
              if (_multiSelection) ...[
                Text('已选 ${_batchUsers.length} 人'),
                TextButton(
                  onPressed: _batchBusy
                      ? null
                      : () {
                          setState(() {
                            for (final user in _items.where(_canSelectUser)) {
                              if (_batchUsers.length >= 500) break;
                              _batchUsers[user.id] = user;
                            }
                          });
                        },
                  child: const Text('选择已加载'),
                ),
                TextButton(
                  onPressed: _batchBusy
                      ? null
                      : () => setState(_batchUsers.clear),
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: _batchUsers.isEmpty
                      ? null
                      : () => setState(() => _showDetail = true),
                  child: const Text('批量设置'),
                ),
              ],
            ],
          ),
        // 状态筛选（单选：全部/正常/锁定/停用）
        Align(
          alignment: Alignment.centerLeft,
          child: UtenSegmentRow<String?>(
            key: const ValueKey('admin-account-status-filter'),
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              const ButtonSegment(value: null, label: Text('全部')),
              for (final key in _statusKeys)
                ButtonSegment(value: key, label: Text(accountStatusLabel(key))),
            ],
            selected: {_statusFilter},
            onSelectionChanged: (next) =>
                _changeStatusFilter(next.isEmpty ? null : next.single),
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        // 开通账号入口：为还没有登录账号的在册员工补开（同人事-员工详情页端点）。
        if (canSupportAccount) _provisionEntry(),
        Expanded(child: _listBody()),
      ],
    );
  }

  /// 「开通账号」入口卡：弹出候选人选择器，成功后刷新账号列表。
  Widget _provisionEntry() {
    final theme = Theme.of(context);
    return UtenCard(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      padding: EdgeInsets.zero,
      onTap: () => showProvisionAccountDialog(context, onProvisioned: _reload),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          children: [
            Icon(
              Icons.person_add_alt_1_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s12),
            const Expanded(
              child: UtenSectionHeader(title: '开通账号', info: '支持多选批量开通'),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _listBody() {
    // 首次加载整块转圈；重查（搜索/状态筛选变化）保留旧列表 + 顶部细进度条
    // ——此前一律整列换成全屏转圈，每个搜索词闪一次（2026-10-18 keepPreviousData
    // 口径）。重查失败且已有数据时保留列表并给内联错误条，不清屏。
    final firstLoad = _loading && _items.isEmpty && _error == null;
    if (firstLoad) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _reload,
      );
    }
    final visible = _items;
    if (visible.isEmpty) {
      return const UtenEmpty(
        icon: Icons.people_outline_rounded,
        message: '暂无匹配的员工账号',
      );
    }
    final list = UtenLoadMoreBoundary(
      enabled:
          !_loading &&
          !_loadingMore &&
          _error == null &&
          !_automaticLoadFailed &&
          _page < _totalPages,
      scope: (
        ref.watch(sensitiveReadBoundaryProvider),
        _search,
        _statusFilter,
        _requestEpoch,
      ),
      onLoadMore: () => _loadMore(automatic: true),
      child: ListView.builder(
        key: const ValueKey('admin-account-list-scroll'),
        // compact 悬浮胶囊避让：滚到底末行要能越过胶囊
        padding: EdgeInsets.only(
          bottom: UtenCapsuleNavScope.occlusionOf(context),
        ),
        itemCount: visible.length + 1,
        itemBuilder: (context, i) {
          if (i == visible.length) {
            if (_page < _totalPages) {
              return Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Center(
                  child: _loadingMore
                      ? const CircularProgressIndicator()
                      : FilledButton.tonal(
                          onPressed: _loadMore,
                          child: const Text('加载更多'),
                        ),
                ),
              );
            }
            return const SizedBox(height: UtenSpacing.s24);
          }
          final u = visible[i];
          return UtenCard(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            onTap: _batchBusy
                ? null
                : () => _multiSelection ? _toggleBatchUser(u) : _onUserTap(u),
            // 选中卡片换全站选中底色 + 主色描边：否则右侧详情换了人，左列看
            // 不出当前是谁（2026-10-27 用户口径「选中要有颜色变化」）。
            selected: _multiSelection
                ? _batchUsers.containsKey(u.id)
                : u.id == _selected?.id,
            child: Row(
              children: [
                if (_multiSelection)
                  Checkbox(
                    key: ValueKey('permission-select-user-${u.id}'),
                    value: _batchUsers.containsKey(u.id),
                    visualDensity: VisualDensity.compact,
                    onChanged: _canSelectUser(u) && !_batchBusy
                        ? (_) => _toggleBatchUser(u)
                        : null,
                  )
                else
                  CircleAvatar(
                    radius: 14,
                    child: Text(
                      (u.employeeName ?? u.loginAccount)
                          .substring(0, 1)
                          .toUpperCase(),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatEmployeeDisplayName(
                          u.employeeName ?? u.loginAccount,
                          u.employeeCode,
                        ),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        [
                          if (u.departmentName?.trim().isNotEmpty == true)
                            u.departmentName!.trim(),
                          u.loginAccount,
                        ].join(' · '),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w400,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                AccountStatusBadge(status: u.status),
              ],
            ),
          );
        },
      ),
    );
    if (!_loading && _error == null) return list;
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          ),
        Expanded(child: list),
      ],
    );
  }
}

/// 账号状态 → 中文标签。
String accountStatusLabel(String status) => switch (status) {
  'active' => '正常',
  'locked' => '锁定',
  'disabled' => '停用',
  _ => status,
};

/// 账号状态徽章（active=绿正常 / locked=红锁定——登录被硬阻断，ADR-169
/// 「锁定不能往下」归红档，非等待；disabled=灰停用）。
class AccountStatusBadge extends StatelessWidget {
  const AccountStatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final type = switch (status) {
      'active' => UtenStatusBadgeType.success,
      'locked' => UtenStatusBadgeType.danger,
      'disabled' => UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
    return UtenStatusBadge(
      label: const {'active', 'locked', 'disabled'}.contains(status)
          ? accountStatusLabel(status)
          : AppLocalizations.of(context).accountStateUnverified,
      type: type,
      size: UtenStatusBadgeSize.small,
    );
  }
}
