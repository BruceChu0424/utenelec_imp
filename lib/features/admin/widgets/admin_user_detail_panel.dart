// AdminUserDetailPanel - 员工权限详情面板
//
// 两段：
//   1. 账号：姓名/工号/部门/状态 + 锁定/解锁/停用/启用/重置密码（危险操作二次确认）
//   2. 权限明细：完整权限目录按 category 层级分组，每个权限点两态显示
//      （已授权 / 未授权），Switch 表示最终有效状态，拨动即调整本地
//      待保存的 grants/revokes，底部「保存覆盖」提交。
//
// 有效权限以后端为准（GET /admin/users/{id}/effective-permissions）：
//   effective = 全员基础 ∪ 部门配置 ∪ 个人加授 − 个人收回
//   前端只根据拨动结果增量维护 grants/revokes，不在本地合成有效权限。
//
// 角色体系已下线（ADR-011 演进）：员工属于哪个部门由「员工档案」维护，
// 权限只分两层——部门配置（集体）+ 个人调整（例外），此面板不再有角色分配。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import '../pages/admin_permissions_page.dart' show AccountStatusBadge;
import 'perm_catalog_group_section.dart';

class AdminUserDetailPanel extends ConsumerStatefulWidget {
  const AdminUserDetailPanel({
    super.key,
    required this.user,
    required this.onAccountChanged,
    this.showBack = false,
    this.onBack,
  });

  final AdminUserSummary user;

  /// 账号操作（锁定/启停/重置密码）成功后回调，用于刷新列表。
  final VoidCallback onAccountChanged;

  final bool showBack;
  final VoidCallback? onBack;

  @override
  ConsumerState<AdminUserDetailPanel> createState() =>
      _AdminUserDetailPanelState();
}

class _AdminUserDetailPanelState extends ConsumerState<AdminUserDetailPanel> {
  /// 本地待保存的加授/收回集合；null = 未做编辑（跟随服务端数据）
  Set<String>? _localGrants;
  Set<String>? _localRevokes;

  bool _savingOverrides = false;
  bool _acting = false;

  // ===== 账号操作 =====

  Future<void> _runAccountAction({
    required String label,
    required bool danger,
    required Future<void> Function(AdminRepository repo) call,
  }) async {
    final confirmed = await UtenDialog.show(
      context,
      title: '$label确认',
      content: Text(
        '确定要对「${widget.user.employeeName ?? widget.user.loginAccount}」执行「$label」吗？',
      ),
      confirmLabel: label,
      danger: danger,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await call(ref.read(adminRepositoryProvider));
      if (!mounted) return;
      UtenToast.success(context, '$label成功');
      widget.onAccountChanged();
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '$label失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  // ===== 覆盖保存 =====

  /// 待保存的加授/收回集合（未编辑时取服务端数据）
  Set<String> _pendingGrants(EffectivePermissions data) =>
      _localGrants ?? data.grants.toSet();
  Set<String> _pendingRevokes(EffectivePermissions data) =>
      _localRevokes ?? data.revokes.toSet();

  /// 拨动某个权限点的最终有效状态：换算为 grants/revokes 的增量调整。
  /// - 打开：原本被收回的移出 revokes；部门/基础没有的加入 grants；
  ///   部门/基础已有的无需覆盖（移出 grants/revokes 回到默认）。
  /// - 关闭：部门/基础来的加入 revokes；本来没有的移出 grants。
  void _togglePerm(EffectivePermissions data, String code, bool value) {
    final base = {...data.departmentPermissions, ...data.baselinePermissions};
    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    setState(() {
      if (value) {
        revokes.remove(code);
        if (base.contains(code)) {
          grants.remove(code);
        } else {
          grants.add(code);
        }
      } else {
        grants.remove(code);
        if (base.contains(code)) {
          revokes.add(code);
        } else {
          revokes.remove(code);
        }
      }
      _localGrants = grants;
      _localRevokes = revokes;
    });
  }

  Future<void> _saveOverrides(EffectivePermissions data) async {
    setState(() => _savingOverrides = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateUserPermOverrides(
            widget.user.id,
            grants: _pendingGrants(data).toList(),
            revokes: _pendingRevokes(data).toList(),
          );
      // 保存成功后重新拉取有效权限刷新显示
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
      if (!mounted) return;
      setState(() {
        _localGrants = null;
        _localRevokes = null;
      });
      UtenToast.success(context, '权限调整已保存');
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveAsync = ref.watch(
      adminEffectivePermissionsProvider(widget.user.id),
    );
    final catalogAsync = ref.watch(permissionCatalogProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (widget.showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('返回列表'),
            ),
          ),
        _accountSection(),
        const SizedBox(height: 12),
        _permSection(effectiveAsync, catalogAsync),
      ],
    );
  }

  // ===== 段 1：账号 =====

  Widget _accountSection() {
    final theme = Theme.of(context);
    final u = widget.user;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '账号',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AccountStatusBadge(status: u.status),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow('姓名', u.employeeName ?? '—'),
          _infoRow('工号', u.employeeCode ?? '—'),
          _infoRow('部门', u.departmentName ?? '—'),
          _infoRow('登录账号', u.loginAccount),
          _infoRow('上次登录', u.lastLoginAt ?? '—'),
          if (u.mustChangePassword)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '该账号已被要求下次登录修改密码',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: UtenColors.warning,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (u.status == 'active')
                UtenButton(
                  type: UtenButtonType.ghost,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_outline_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '锁定',
                    danger: true,
                    call: (r) => r.lockUser(u.id),
                  ),
                  child: const Text('锁定'),
                ),
              if (u.status == 'locked')
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_open_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '解锁',
                    danger: false,
                    call: (r) => r.unlockUser(u.id),
                  ),
                  child: const Text('解锁'),
                ),
              if (u.status != 'disabled')
                UtenButton(
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.small,
                  icon: Icons.block_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '停用',
                    danger: true,
                    call: (r) => r.disableUser(u.id),
                  ),
                  child: const Text('停用'),
                ),
              if (u.status == 'disabled')
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.play_circle_outline_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '启用',
                    danger: false,
                    call: (r) => r.enableUser(u.id),
                  ),
                  child: const Text('启用'),
                ),
              UtenButton(
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                icon: Icons.key_rounded,
                isLoading: _acting,
                onPressed: () => _runAccountAction(
                  label: '重置密码',
                  danger: true,
                  call: (r) => r.resetPassword(u.id),
                ),
                child: const Text('重置密码'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段 2：权限明细（两态：已授权 / 未授权） =====

  Widget _permSection(
    AsyncValue<EffectivePermissions> effectiveAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
  ) {
    final theme = Theme.of(context);
    final data = effectiveAsync.valueOrNull;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '权限明细',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最终有效权限 = 全员基础 ∪ 部门配置 ∪ 个人加授 − 个人收回。'
            '拨动开关调整个人加授/收回，保存后生效。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // 超管提示：恒为全量权限，此页仅展示不可调整
          if (data?.superAdmin ?? false) ...[
            const SizedBox(height: 6),
            Text(
              '该账号是超级管理员，默认拥有全部权限，无需也不能在此调整。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: UtenColors.warning,
              ),
            ),
          ],
          // 部门行（无部门则不显示）
          if (data?.departmentName != null) ...[
            const SizedBox(height: 6),
            Text(
              '部门：${data!.departmentName} · '
              '部门已配 ${data.departmentPermissions.length} 项权限',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _permMatrix(effectiveAsync, catalogAsync),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              size: UtenButtonSize.small,
              isLoading: _savingOverrides,
              onPressed: data == null || data.superAdmin
                  ? null
                  : () => _saveOverrides(data),
              child: const Text('保存覆盖'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '权限变更将在该用户下次登录或令牌刷新后生效',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _permMatrix(
    AsyncValue<EffectivePermissions> effectiveAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
  ) {
    if (effectiveAsync.hasError || catalogAsync.hasError) {
      return _loadError('权限数据加载失败');
    }
    final data = effectiveAsync.valueOrNull;
    final groups = catalogAsync.valueOrNull;
    if (data == null || groups == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (groups.isEmpty) {
      return _loadError('权限目录为空');
    }

    // 完整目录按 category 分组展示（动态目录，不硬编码权限清单）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups)
          PermCatalogGroupSection(
            title: group.category,
            // 组内已授权/总数，与两态主标签口径一致
            countLabel:
                '${group.permissions.where((p) => _isEffective(data, p.code)).length}/${group.permissions.length}',
            children: [
              for (final p in group.permissions) _permRow(data, p),
            ],
          ),
      ],
    );
  }

  /// 某权限点对该员工的最终有效状态（与 _permRow 主标签同一口径）
  bool _isEffective(EffectivePermissions data, String code) {
    // 超管恒为全量：直接以后端 effective 为准
    if (data.superAdmin) return true;
    final viaDept = data.departmentPermissions.contains(code);
    final viaBaseline = data.baselinePermissions.contains(code);
    final revoked = _pendingRevokes(data).contains(code);
    return ((viaDept || viaBaseline) && !revoked) ||
        _pendingGrants(data).contains(code);
  }

  Widget _permRow(EffectivePermissions data, AdminPermission p) {
    final theme = Theme.of(context);
    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    final viaDept = data.departmentPermissions.contains(p.code);
    final viaBaseline = data.baselinePermissions.contains(p.code);
    final revoked = !data.superAdmin && revokes.contains(p.code);
    // 最终有效状态：超管恒 true；否则 部门/基础所得且未被收回，或被个人加授
    final effective = data.superAdmin ||
        ((viaDept || viaBaseline) && !revoked) ||
        grants.contains(p.code);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    Text(
                      p.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        // 被收回的权限名用红色弱化 + 删除线
                        color: revoked ? UtenColors.error : null,
                        decoration: revoked ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Text(
                      p.code,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    if (viaDept) _sourceTag('部门'),
                    if (viaBaseline) _sourceTag('基础'),
                    if (grants.contains(p.code)) _sourceTag('个人加授'),
                    if (revoked) _sourceTag('已收回', danger: true),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 两态主标签：已授权（绿）/ 未授权（灰）
          UtenStatusBadge(
            label: effective ? '已授权' : '未授权',
            type: effective
                ? UtenStatusBadgeType.success
                : UtenStatusBadgeType.neutral,
            size: UtenStatusBadgeSize.small,
          ),
          const SizedBox(width: 4),
          // 超管恒为全量，开关禁用（个人覆盖对超管无意义，后端也拦截写入）
          Switch(
            value: effective,
            onChanged: data.superAdmin
                ? null
                : (v) => _togglePerm(data, p.code, v),
          ),
        ],
      ),
    );
  }

  /// 来源小标签（部门 / 基础 / 个人加授 / 已收回）
  Widget _sourceTag(String label, {bool danger = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: danger
            ? UtenColors.error.withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: danger ? UtenColors.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _loadError(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: UtenColors.error),
      ),
    );
  }
}
