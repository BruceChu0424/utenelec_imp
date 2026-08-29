// AdminPermissionsPage - 账号支持与权限管理。
//
// account:support 可执行账号锁定/启停/重置密码。
// authorization:manage + superAdmin 才显示个人/部门授权与数据范围。
// 顶部说明条 + 超管可见的分段切换「按员工 | 按部门」。
// 按员工：主从布局（expanded 左列表右详情；compact 列表 → 详情带返回）。
// 按部门：单选部门 + 从完整权限目录勾选权限点（见 widgets/admin_department_perm_view.dart）。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 路由守卫与工作台显隐共用 permission_by_path.dart。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/employee_display.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';
import '../widgets/admin_department_perm_view.dart';
import '../widgets/admin_user_detail_panel.dart';
import '../widgets/provision_account_dialog.dart';

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
  /// 0=按员工，1=按部门
  int _segment = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialDepartmentId != null) _segment = 1;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canManageAuthorization =
        ref.watch(isSuperAdminProvider) &&
        permissions.contains(Perm.authorizationManage);
    final segment = canManageAuthorization ? _segment : 0;

    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部说明条
        UtenCard(
          margin: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s12,
          ),
          child: Row(
            children: [
              Icon(
                Icons.admin_panel_settings_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  canManageAuthorization
                      ? '账号与权限管理 · 账号操作、个人权限、数据范围和部门权限均以后端实时授权为准。'
                      : '账号支持 · 可锁定、启停账号或重置一次性临时密码；不展示任何授权配置。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 分段切换
        if (canManageAuthorization)
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: UtenSegmentedFilter<int>(
              segments: const [
                UtenSegment(value: 0, label: '按员工'),
                UtenSegment(value: 1, label: '按部门'),
              ],
              selected: segment,
              onChanged: (value) => setState(() => _segment = value),
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: segment,
            children: [
              _EmployeePermTab(
                canManageAuthorization: canManageAuthorization,
                initialEmployeeId: widget.initialEmployeeId,
              ),
              if (canManageAuthorization)
                AdminDepartmentPermView(
                  initialDepartmentId: widget.initialDepartmentId,
                ),
            ],
          ),
        ),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    // 统一顶栏：左上角全局返回键（UtenBackButton），AppBar 自带顶部安全区
    return Scaffold(
      appBar: UtenAppBar(
        title: canManageAuthorization ? '账号与权限管理' : '账号支持',
        showBackButton: true,
      ),
      body: body,
    );
  }
}

/// 按员工：账号列表（搜索/状态筛选/加载更多）+ 详情面板（主从布局）。
class _EmployeePermTab extends ConsumerStatefulWidget {
  const _EmployeePermTab({
    required this.canManageAuthorization,
    this.initialEmployeeId,
  });

  final bool canManageAuthorization;

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
  String? _error;
  int _requestEpoch = 0;

  AdminUserSummary? _selected;
  bool _showDetail = false; // compact 下是否进入详情视图
  bool _detailDirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
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
    if (!mounted) return;
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
    setState(() {
      _loading = true;
      _loadingMore = false;
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
      if (!mounted || requestEpoch != _requestEpoch) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _totalPages = r.totalPages;
        _loading = false;
        // 列表刷新后同步选中项（状态/角色可能已变更）
        final sel = _selected;
        if (sel != null) {
          AdminUserSummary? found;
          for (final e in r.items) {
            if (e.id == sel.id) {
              found = e;
              break;
            }
          }
          _selected = found ?? (_detailDirty ? sel : null);
        }
      });
    } on ApiException catch (e) {
      if (!mounted || requestEpoch != _requestEpoch) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestEpoch != _requestEpoch) return;
      setState(() {
        _error = '加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    final requestEpoch = _requestEpoch;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .listUsers(
            page: nextPage,
            search: _search.isEmpty ? null : _search,
            status: _statusFilter,
          );
      if (!mounted || requestEpoch != _requestEpoch) return;
      setState(() {
        _items.addAll(r.items);
        _page = nextPage;
        _totalPages = r.totalPages;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || requestEpoch != _requestEpoch) return;
      setState(() => _loadingMore = false);
    }
  }

  void _changeStatusFilter(String? status) {
    if (status == _statusFilter) return;
    setState(() => _statusFilter = status);
    _reload();
  }

  Future<bool> _confirmDiscardPermissionChanges() async {
    if (!_detailDirty) return true;
    final confirmed = await UtenDialog.show(
      context,
      title: '丢弃未保存修改',
      content: const Text('当前员工有未保存的权限修改，离开后将丢弃这些修改。确定继续吗？'),
      confirmLabel: '丢弃并离开',
      danger: true,
    );
    return mounted && confirmed == true;
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
      _detailDirty = false;
    });
  }

  Future<void> _onBack() async {
    if (!await _confirmDiscardPermissionChanges()) return;
    if (!mounted) return;
    setState(() {
      _showDetail = false;
      _detailDirty = false;
    });
  }

  /// 详情面板完成账号操作后回调：刷新列表并同步选中项。
  void _onAccountChanged() => _reload();

  @override
  Widget build(BuildContext context) {
    final isExpanded =
        context.breakpoint.isExpanded &&
        MediaQuery.sizeOf(context).width >= 1100;
    if (isExpanded) {
      return UtenSplitView(
        persistenceKey: 'admin.permissions',
        initialLeadingWidth: 320,
        leading: _listColumn(),
        trailing: _detailArea(showBack: false),
      );
    }
    // compact：列表 ↔ 详情 切换
    return _showDetail && _selected != null
        ? _detailArea(showBack: true)
        : _listColumn();
  }

  Widget _detailArea({required bool showBack}) {
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
      key: ValueKey(u.id),
      user: u,
      canManageAuthorization: widget.canManageAuthorization,
      showBack: showBack,
      onBack: _onBack,
      onAccountChanged: _onAccountChanged,
      onPermissionDirtyChanged: (dirty) => _detailDirty = dirty,
    );
  }

  Widget _listColumn() {
    // 与人事-员工详情页同权限级：account:support 可补开登录账号。
    final canSupportAccount = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.accountSupport);
    return Column(
      children: [
        // 搜索框（按登录账号搜）：UtenSearchBar 自带 300ms 防抖 + 清除按钮
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSearchBar(
            hint: '搜索登录账号',
            onChanged: (v) {
              final t = v.trim();
              if (t != _search) {
                _search = t;
                _reload();
              }
            },
          ),
        ),
        // 状态筛选（单选：全部/正常/锁定/停用）
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: _statusFilter == null,
                  onSelected: (_) => _changeStatusFilter(null),
                ),
              ),
              for (final key in _statusKeys)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                  ),
                  child: ChoiceChip(
                    label: Text(accountStatusLabel(key)),
                    selected: _statusFilter == key,
                    onSelected: (_) =>
                        _changeStatusFilter(_statusFilter == key ? null : key),
                  ),
                ),
            ],
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
          vertical: UtenSpacing.s12,
        ),
        child: Row(
          children: [
            Icon(
              Icons.person_add_alt_1_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '开通账号',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '员工还没有登录账号？点此补开(初始密码首登强制修改)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
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
    return ListView.builder(
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
          margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          onTap: () => _onUserTap(u),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
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
                      style: Theme.of(context).textTheme.titleMedium,
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
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w400,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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

/// 账号状态徽章（active=绿 / locked=黄 / disabled=灰）。
class AccountStatusBadge extends StatelessWidget {
  const AccountStatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final type = switch (status) {
      'active' => UtenStatusBadgeType.success,
      'locked' => UtenStatusBadgeType.warning,
      'disabled' => UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
    return UtenStatusBadge(
      label: accountStatusLabel(status),
      type: type,
      size: UtenStatusBadgeSize.small,
    );
  }
}
