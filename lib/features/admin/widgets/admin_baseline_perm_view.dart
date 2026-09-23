// AdminBaselinePermView - 全员基础包：每个在职员工都默认拥有的权限。
//
// 基础包取代了原来的「全员角色」(ADR-109)：只有超级管理员能改，保存时服务端按差量落库，
// 能否放进基础包只看服务端下发的授权策略(需要逐项授予 / 只能逐人授予 / 超管专属的码不行)。
// 基础包只能逐项勾选，不提供「全部授权」，避免一次把大量权限发给全公司。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'permission_action_badge.dart';
import 'permission_catalog_browser.dart';

class AdminBaselinePermView extends ConsumerStatefulWidget {
  const AdminBaselinePermView({super.key});

  @override
  ConsumerState<AdminBaselinePermView> createState() =>
      _AdminBaselinePermViewState();
}

class _AdminBaselinePermViewState extends ConsumerState<AdminBaselinePermView> {
  Set<String>? _localChecked;
  bool _saving = false;

  Set<String>? get _serverChecked =>
      ref.read(adminPermissionBaselineProvider).valueOrNull?.toSet();

  Set<String> get _checked =>
      _localChecked ?? _serverChecked ?? const <String>{};

  bool get _isDirty {
    final local = _localChecked;
    final server = _serverChecked;
    return local != null && server != null && !setEquals(local, server);
  }

  int get _dirtyCount {
    final local = _localChecked;
    final server = _serverChecked;
    if (local == null || server == null) return 0;
    return {
      ...local,
      ...server,
    }.where((code) => local.contains(code) != server.contains(code)).length;
  }

  void _setPermissions(Iterable<String> codes, bool value) {
    setState(() {
      final next = {..._checked};
      value ? next.addAll(codes) : next.removeAll(codes);
      _localChecked = next;
    });
  }

  Future<void> _save() async {
    if (_saving || !_isDirty) return;
    setState(() => _saving = true);
    try {
      final change = await ref
          .read(adminRepositoryProvider)
          .updatePermissionBaseline(_checked.toList());
      ref
        ..invalidate(adminPermissionBaselineProvider)
        ..invalidate(permissionCatalogProvider);
      if (!mounted) return;
      setState(() => _localChecked = null);
      context.appSuccess(
        '已保存全员基础包：新增 ${change.added.length} 项，'
        '移出 ${change.removed.length} 项，即时生效',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error, fallback: '保存失败，本地修改已保留，请稍后重试');
    } catch (_) {
      if (mounted) context.appError('保存失败，本地修改已保留，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baselineAsync = ref.watch(adminPermissionBaselineProvider);
    final catalogAsync = ref.watch(permissionCatalogProvider);
    final checked = _checked;

    return Column(
      children: [
        if (_saving)
          const UtenBusyOverlay(
            title: '正在保存全员基础包',
            description: '正在写入基础包变更，请勿重复提交或离开本页。',
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              UtenSpacing.s32,
            ),
            children: [
              UtenCard(
                margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                  vertical: UtenSpacing.s12,
                ),
                child: Text(
                  '基础包里的权限每个在职员工都默认拥有，不用再按部门或个人配置。'
                  '只放大家都该有的自助类权限；需要逐项授予的敏感权限不能放进来。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
              UtenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '全员基础包',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isDirty
                          ? '已包含 ${checked.length} 项 · $_dirtyCount 项未保存'
                          : '已包含 ${checked.length} 项',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _isDirty
                            ? UtenColors.warning
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    _body(baselineAsync, catalogAsync, checked),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_isDirty)
          UtenBottomActionBar(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已修改 $_dirtyCount 项',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _localChecked = null),
                  child: const Text('撤销'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _saving,
                  onPressed: _saving ? null : _save,
                  child: const Text('保存更改'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<String>> baselineAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
    Set<String> checked,
  ) {
    if (baselineAsync.hasError || catalogAsync.hasError) {
      return UtenEmpty.error(
        message: '全员基础包加载失败',
        description: '请检查网络后重试。',
        actionLabel: '重试',
        onAction: () => ref
          ..invalidate(adminPermissionBaselineProvider)
          ..invalidate(permissionCatalogProvider),
      );
    }
    final rawGroups = catalogAsync.valueOrNull;
    if (rawGroups == null || baselineAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // 只显示能放进基础包的码；已在包里的仍显示，便于移出。
    final groups = rawGroups
        .map(
          (group) => PermissionCatalogGroup(
            module: group.module,
            category: group.category,
            permissions: group.permissions
                .where(
                  (permission) =>
                      permission.grantPolicy.baselineEligible ||
                      checked.contains(permission.code),
                )
                .toList(growable: false),
          ),
        )
        .where((group) => group.permissions.isNotEmpty)
        .toList(growable: false);
    if (groups.isEmpty) {
      return const UtenEmpty(
        icon: Icons.security_outlined,
        message: '权限目录为空',
        description: '后端尚未返回可配置的权限点。',
      );
    }
    return PermissionCatalogBrowser(
      groups: groups,
      enabledFilterLabel: '已包含',
      disabledFilterLabel: '未包含',
      disableGroupLabel: '本组全部移出',
      disableModuleLabel: '本模块全部移出',
      isEnabled: (permission) => checked.contains(permission.code),
      onDisableGroup: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      itemBuilder: (context, permission) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
        child: Row(
          children: [
            Expanded(
              child: PermissionTitleBlock(
                name: permission.name,
                actionType: permission.actionType,
                description: permission.description,
                grantPolicy: permission.grantPolicy,
                sensitivity: permission.sensitivity,
                nameStyle: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Semantics(
              label:
                  '${permission.name}${checked.contains(permission.code) ? '已包含' : '未包含'}',
              child: Switch(
                key: ValueKey('baseline-switch-${permission.code}'),
                value: checked.contains(permission.code),
                onChanged: (value) => _setPermissions([permission.code], value),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
