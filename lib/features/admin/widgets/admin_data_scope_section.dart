import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';
import 'admin_data_handover_panel.dart';

/// 服务端 catalog 驱动的“可查看数据”配置。
class AdminDataScopeSection extends ConsumerStatefulWidget {
  const AdminDataScopeSection({
    super.key,
    required this.user,
    required this.effectiveAsync,
    this.onAccountChanged,
  });

  final AdminUserSummary user;
  final AsyncValue<EffectivePermissions> effectiveAsync;
  final VoidCallback? onAccountChanged;

  @override
  ConsumerState<AdminDataScopeSection> createState() =>
      _AdminDataScopeSectionState();
}

class _AdminDataScopeSectionState extends ConsumerState<AdminDataScopeSection> {
  List<DataScopeCatalogItem> _catalog = const [];
  bool _requested = false;
  bool _catalogLoading = false;
  String? _catalogError;
  final Set<String> _loading = {};
  final Set<String> _saving = {};
  final Map<String, String> _errors = {};
  final Map<String, Set<String>> _grants = {};
  final Map<String, List<DataScopeOwner>> _candidates = {};
  final Map<String, int> _revisions = {};

  @override
  void didUpdateWidget(covariant AdminDataScopeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id != widget.user.id ||
        oldWidget.user.status != widget.user.status ||
        oldWidget.user.currentEmployee != widget.user.currentEmployee) {
      _reset();
    }
  }

  void _reset() {
    _requested = false;
    _catalog = const [];
    _catalogLoading = false;
    _catalogError = null;
    _loading.clear();
    _saving.clear();
    _errors.clear();
    _grants.clear();
    _candidates.clear();
    _revisions.clear();
  }

  Future<void> _loadAll(EffectivePermissions permissions) async {
    if (_requested) return;
    _requested = true;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
    });
    final userId = widget.user.id;
    try {
      final catalog = await ref
          .read(adminRepositoryProvider)
          .dataScopeCatalog();
      if (!mounted || widget.user.id != userId) return;
      setState(() {
        _catalog = catalog;
        _catalogLoading = false;
      });
      final effective = permissions.effective.toSet();
      await Future.wait(
        catalog
            .where(
              (item) =>
                  item.enabled &&
                  (item.viewAllPermission.isEmpty ||
                      !effective.contains(item.viewAllPermission)),
            )
            .map(_loadScope),
      );
    } catch (_) {
      if (!mounted || widget.user.id != userId) return;
      setState(() {
        _catalogLoading = false;
        _catalogError = '可查看数据目录加载失败，请重试';
      });
    }
  }

  Future<void> _retryCatalog(EffectivePermissions permissions) async {
    setState(() {
      _reset();
    });
    await _loadAll(permissions);
  }

  Future<void> _loadScope(DataScopeCatalogItem definition) async {
    final scope = definition.scope;
    final userId = widget.user.id;
    setState(() {
      _loading.add(scope);
      _errors.remove(scope);
    });
    try {
      final repository = ref.read(adminRepositoryProvider);
      final results = await Future.wait<Object>([
        repository.getUserDataScopes(userId, scope),
        repository.dataScopeOwners(scope),
      ]);
      if (!mounted || widget.user.id != userId) return;
      setState(() {
        _grants[scope] = (results[0] as List<String>).toSet();
        _candidates[scope] = results[1] as List<DataScopeOwner>;
      });
    } catch (_) {
      if (!mounted || widget.user.id != userId) return;
      setState(() => _errors[scope] = '加载失败，请重试');
    } finally {
      if (mounted && widget.user.id == userId) {
        setState(() => _loading.remove(scope));
      }
    }
  }

  Future<void> _saveSelection(
    DataScopeCatalogItem definition,
    List<UtenEmployeePickerItem> selection,
  ) async {
    final scope = definition.scope;
    if (_saving.contains(scope)) return;
    final previous = {...?_grants[scope]};
    final selected = selection.map((item) => item.id).toSet();
    if (_sameIds(previous, selected)) return;
    if (!widget.user.authorizationGrantAllowed && selected.isNotEmpty) {
      UtenToast.info(context, widget.user.authorizationRestrictionReason);
      setState(() => _bumpRevision(scope));
      return;
    }

    final confirmed = await UtenDialog.show(
      context,
      title: '确认修改可查看数据？',
      content: Text(
        '员工：${widget.user.employeeName ?? widget.user.loginAccount}\n'
        '范围：${definition.displayLabel}\n'
        '额外查看：${selected.length} 人\n\n'
        '额外查看不会改变数据负责人，默认只读；其他操作仍由独立操作权限控制。',
      ),
      confirmLabel: '确认保存',
    );
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => _bumpRevision(scope));
      return;
    }

    setState(() {
      _saving.add(scope);
      _grants[scope] = selected;
    });
    try {
      final ids = selected.toList()..sort();
      final expectedIds = previous.toList()..sort();
      await ref
          .read(adminRepositoryProvider)
          .updateUserDataScopes(
            widget.user.id,
            scope,
            ids,
            expectedOwnerEmployeeIds: expectedIds,
          );
      if (!mounted) return;
      UtenToast.success(context, '${definition.displayLabel}已保存，即时生效');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _grants[scope] = previous;
        _bumpRevision(scope);
      });
      if (error.code == 'CONFLICT') {
        widget.onAccountChanged?.call();
        UtenToast.error(
          context,
          '${error.message.isEmpty ? '账号或数据范围已变化' : error.message}；正在刷新最新设置',
        );
        await _loadScope(definition);
      } else {
        UtenToast.error(context, error.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _grants[scope] = previous;
        _bumpRevision(scope);
      });
      UtenToast.error(context, '保存失败，已恢复原设置');
    } finally {
      if (mounted) setState(() => _saving.remove(scope));
    }
  }

  void _bumpRevision(String scope) {
    _revisions[scope] = (_revisions[scope] ?? 0) + 1;
  }

  List<UtenEmployeePickerItem> _scopeItems(String scope) => [
    for (final candidate in _candidates[scope] ?? const <DataScopeOwner>[])
      UtenEmployeePickerItem(
        id: candidate.employeeId,
        name: candidate.name,
        departmentName: candidate.historicalOnly
            ? '历史只读 · 原负责人名下 ${candidate.count} 条数据'
            : '负责 ${candidate.count} 条数据',
      ),
  ];

  List<UtenEmployeePickerItem> _selection(String scope) {
    final items = {for (final item in _scopeItems(scope)) item.id: item};
    return [
      for (final id in _grants[scope] ?? const <String>{})
        items[id] ??
            UtenEmployeePickerItem(
              id: id,
              name: '未知员工',
              departmentName: '已授权，但当前没有归属数据',
            ),
    ];
  }

  bool _viewAllActive(
    DataScopeCatalogItem definition,
    EffectivePermissions permissions,
  ) =>
      definition.viewAllPermission.isNotEmpty &&
      permissions.effective.contains(definition.viewAllPermission);

  void _ensureScopeLoaded(DataScopeCatalogItem definition) {
    final scope = definition.scope;
    if (_grants.containsKey(scope) ||
        _loading.contains(scope) ||
        _errors.containsKey(scope)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _grants.containsKey(scope) ||
          _loading.contains(scope) ||
          _errors.containsKey(scope)) {
        return;
      }
      unawaited(_loadScope(definition));
    });
  }

  Future<void> _openHandover(EffectivePermissions permissions) async {
    final employeeId = widget.user.employeeId;
    if (employeeId == null || employeeId.isEmpty) return;
    if (!widget.user.authorizationGrantAllowed) {
      UtenToast.info(context, widget.user.authorizationRestrictionReason);
      return;
    }
    final result = await showAdminDataHandoverPanel(
      context: context,
      ref: ref,
      targetEmployeeId: employeeId,
      targetName: widget.user.employeeName ?? widget.user.loginAccount,
    );
    if (!mounted || result == null) return;
    setState(_reset);
    await _loadAll(permissions);
  }

  @override
  Widget build(BuildContext context) {
    final permissions = widget.effectiveAsync.valueOrNull;
    if (widget.effectiveAsync.hasError) {
      return UtenCard(child: UtenEmpty.error(message: '账号权限状态加载失败'));
    }
    if (permissions == null) {
      return const UtenCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (!permissions.superAdmin && !_requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_requested) unawaited(_loadAll(permissions));
      });
    }

    final theme = Theme.of(context);
    final canHandover =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.employeeHandover);
    final canReceiveHandover = widget.user.authorizationGrantAllowed;
    final authorizationBlocked = !widget.user.authorizationGrantAllowed;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '可查看数据',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '默认只查看本人负责的数据。可按模块额外查看指定负责人的数据；'
            '额外查看不改变负责人，默认只读。离职原负责人会标记“历史只读”，'
            '只增加其原历史数据，不会随当前接手人的新增数据扩大。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (authorizationBlocked && !permissions.superAdmin) ...[
            const SizedBox(height: UtenSpacing.s12),
            _notice(
              '${widget.user.authorizationRestrictionReason}。'
              '不能新增额外查看范围；已有范围仍可一键清空。',
              Icons.lock_person_outlined,
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (canHandover &&
              widget.user.employeeId?.isNotEmpty == true &&
              canReceiveHandover &&
              !permissions.superAdmin) ...[
            Align(
              alignment: Alignment.centerRight,
              child: UtenButton(
                key: const ValueKey('admin-data-handover-entry'),
                type: UtenButtonType.secondary,
                icon: Icons.swap_horiz_rounded,
                onPressed: () => _openHandover(permissions),
                child: const Text('人员数据交接'),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (canHandover &&
              widget.user.employeeId?.isNotEmpty == true &&
              !canReceiveHandover &&
              !permissions.superAdmin) ...[
            _notice(
              widget.user.currentEmployee
                  ? '当前账号未启用，不能作为数据接手人；可先启用账号，或选择其他在职接手人。'
                  : '${widget.user.employeeStatusLabel}员工不能作为数据接手人；'
                        '如需交出其历史数据，请使用离职办理，或从在职接手人的权限页发起人员数据交接。',
              Icons.lock_outline_rounded,
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (permissions.superAdmin)
            _notice('该账号是超级管理员，默认查看全部数据，无需配置。', Icons.visibility_outlined)
          else if (_catalogLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_catalogError != null)
            UtenEmpty.error(
              message: _catalogError,
              actionLabel: '重试',
              onAction: () => unawaited(_retryCatalog(permissions)),
            )
          else if (_catalog.isEmpty)
            const UtenEmpty(
              icon: Icons.visibility_off_outlined,
              message: '当前没有可配置的数据范围',
            )
          else
            ..._groupedSections(permissions),
        ],
      ),
    );
  }

  List<Widget> _groupedSections(EffectivePermissions permissions) {
    final theme = Theme.of(context);
    final groups = <String, List<DataScopeCatalogItem>>{};
    for (final item in _catalog) {
      groups.putIfAbsent(item.group, () => []).add(item);
    }
    return [
      for (final entry in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s8,
            bottom: UtenSpacing.s8,
          ),
          child: Text(
            entry.key,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final definition in entry.value) ...[
          _scopeCard(definition, permissions),
          const SizedBox(height: UtenSpacing.s8),
        ],
      ],
    ];
  }

  Widget _scopeCard(
    DataScopeCatalogItem definition,
    EffectivePermissions permissions,
  ) {
    final theme = Theme.of(context);
    final scope = definition.scope;
    final viewAll = _viewAllActive(definition, permissions);
    if (definition.enabled && !viewAll) {
      _ensureScopeLoaded(definition);
    }
    final count = _grants[scope]?.length ?? 0;
    final (statusLabel, statusType) = !definition.enabled
        ? ('功能未启用', UtenStatusBadgeType.neutral)
        : viewAll
        ? ('查看全部覆盖', UtenStatusBadgeType.warning)
        : count > 0
        ? ('额外查看 $count 人', UtenStatusBadgeType.info)
        : ('仅本人', UtenStatusBadgeType.success);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  definition.displayLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenStatusBadge(
                label: statusLabel,
                type: statusType,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          if (definition.displayDescription.trim().isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              definition.displayDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          if (!definition.enabled)
            _notice(
              definition.disabledReason?.trim().isNotEmpty == true
                  ? definition.disabledReason!.trim()
                  : '该功能当前未启用，现有设置不会生效。',
              Icons.pause_circle_outline_rounded,
            )
          else if (viewAll)
            _notice(
              '已由“${definition.viewAllPermission}”覆盖为查看全部；下方负责人范围不再生效。',
              Icons.visibility_outlined,
            )
          else if (_loading.contains(scope))
            const Row(
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: UtenSpacing.s8),
                Text('正在加载负责人…'),
              ],
            )
          else if (_errors[scope] != null)
            Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(child: Text(_errors[scope]!)),
                TextButton(
                  onPressed: () => _loadScope(definition),
                  child: const Text('重试'),
                ),
              ],
            )
          else
            _picker(definition),
        ],
      ),
    );
  }

  Widget _picker(DataScopeCatalogItem definition) {
    final scope = definition.scope;
    final items = _scopeItems(scope);
    final selected = _selection(scope);
    final granted = _grants[scope] ?? const <String>{};
    final historicalSelected = (_candidates[scope] ?? const <DataScopeOwner>[])
        .where(
          (candidate) =>
              candidate.historicalOnly &&
              granted.contains(candidate.employeeId),
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (historicalSelected > 0) ...[
          _notice(
            '已包含 $historicalSelected 位历史只读原负责人；仅查看其原历史数据，不随当前接手人的范围扩大。',
            Icons.history_rounded,
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        UtenEmployeeMultiPicker(
          key: ValueKey(
            'scope-$scope-${_revisions[scope] ?? 0}-'
            '${selected.map((item) => item.id).join(',')}',
          ),
          label: '额外查看哪些负责人的数据',
          hint: '仅本人负责的数据',
          sheetTitle: '配置${definition.displayLabel}',
          searchHint: '搜索负责人姓名',
          emptyMessage: '暂无匹配且拥有归属数据的负责人',
          selectedCountLabel: (count) => '额外查看 $count 人',
          initialSelection: selected,
          enabled:
              widget.user.authorizationGrantAllowed && !_saving.contains(scope),
          loader: (keyword) async {
            final query = keyword?.trim().toLowerCase() ?? '';
            if (query.isEmpty) return items;
            return items
                .where((item) => item.name.toLowerCase().contains(query))
                .toList(growable: false);
          },
          onChanged: (next) => unawaited(_saveSelection(definition, next)),
        ),
        if (!widget.user.authorizationGrantAllowed && granted.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              key: ValueKey('clear-data-scope-$scope'),
              type: UtenButtonType.ghost,
              size: UtenButtonSize.small,
              icon: Icons.delete_sweep_outlined,
              isLoading: _saving.contains(scope),
              onPressed: _saving.contains(scope)
                  ? null
                  : () => unawaited(
                      _saveSelection(
                        definition,
                        const <UtenEmployeePickerItem>[],
                      ),
                    ),
              child: const Text('清空额外查看'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _notice(String message, IconData icon) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

bool _sameIds(Set<String> left, Set<String> right) =>
    left.length == right.length && left.every(right.contains);
