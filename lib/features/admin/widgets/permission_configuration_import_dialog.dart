import 'package:flutter/material.dart';
import 'admin_account_lifecycle_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/widgets/department_employee_picker.dart';
import '../models/permission_configuration.dart';
import '../repositories/admin_repository.dart';
import '../repositories/permission_configuration_repository.dart';
import 'admin_permission_transfer_actions.dart'
    show permissionTransferError, refreshPermissionConfiguration;
import 'permission_transfer_preview.dart';

class PermissionConfigurationImportDialog extends ConsumerStatefulWidget {
  const PermissionConfigurationImportDialog({
    super.key,
    required this.configuration,
    required this.boundary,
  });
  final PermissionConfiguration configuration;
  final SensitiveReadBoundary boundary;

  @override
  ConsumerState<PermissionConfigurationImportDialog> createState() =>
      _ImportState();
}

class _Target {
  _Target(
    this.kind,
    this.key,
    this.label, {
    this.restorable = true,
    this.reason,
  }) : selected = restorable;
  final String kind;
  final String key;
  final String label;
  final bool restorable;
  final String? reason;
  bool selected;
  String? targetId;
  String? targetLabel;
  Map<String, dynamic> toJson() => {'sourceKey': key, 'targetId': targetId};
}

class _ImportState extends ConsumerState<PermissionConfigurationImportDialog> {
  final List<_Target> _departments = [];
  final List<_Target> _users = [];
  final List<_Target> _owners = [];
  final Set<String> _confirmed = {};
  bool _baseline = true;
  bool _dataScopes = true;
  bool _mappingConfirmed = false;
  bool _loading = true;
  bool _applying = false;
  bool _uncertain = false;
  bool _boundaryFailed = false;
  bool _initialized = false;
  String? _error;
  PermissionTransferPreview? _preview;
  late final Future<AuthenticatedRequestScope> _scope;

  bool get _current =>
      mounted &&
      widget.boundary == ref.read(sensitiveReadBoundaryProvider) &&
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

  @override
  void initState() {
    super.initState();
    _baseline = widget.configuration.includesBaseline;
    _dataScopes = widget.configuration.includesDataScopes;
    for (final entry in widget.configuration.departments) {
      _departments.add(
        _Target(
          'department',
          entry['key'] as String,
          '${entry['name']}（${entry['code']}）',
        ),
      );
    }
    for (final entry in widget.configuration.users) {
      final state = switch (entry['accountStatus']) {
        'locked' => ' · 来源账号已锁定',
        'disabled' => ' · 来源账号已停用',
        _ => '',
      };
      _users.add(
        _Target(
          'user',
          entry['key'] as String,
          '${entry['employeeName']}（${entry['employeeCode']}） · ${entry['loginAccount']}$state',
          restorable: entry['restorable'] != false,
          reason: entry['restoreReason'] as String?,
        ),
      );
    }
    for (final entry in widget.configuration.owners) {
      _owners.add(
        _Target(
          'owner',
          entry['key'] as String,
          '${entry['name']}（${entry['code']}）',
        ),
      );
    }
    _scope = ref
        .read(apiClientProvider)
        .captureRequestScope(isCurrent: () => _current);
    _suggest();
  }

  Set<String> get _requiredOwners {
    if (!_dataScopes) return {};
    final selectedUsers = _users
        .where((item) => item.selected)
        .map((item) => item.key)
        .toSet();
    return {
      for (final user in widget.configuration.users)
        if (selectedUsers.contains(user['key']))
          for (final owners
              in (user['dataScopes'] as Map<String, dynamic>? ?? {}).values)
            for (final owner in owners as List) owner as String,
    };
  }

  Map<String, dynamic> _request() {
    final requiredOwners = _requiredOwners;
    return {
      'configuration': widget.configuration.json,
      'importBaseline': _baseline,
      'departments': [
        for (final target in _departments)
          if (target.selected) target.toJson(),
      ],
      'users': [
        for (final target in _users)
          if (target.selected) target.toJson(),
      ],
      'importDataScopes': _dataScopes,
      'owners': [
        for (final target in _owners)
          if (requiredOwners.contains(target.key)) target.toJson(),
      ],
    };
  }

  Future<void> _suggest() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = await _scope;
      final result = await scope.run(
        () => ref
            .read(permissionConfigurationRepositoryProvider)
            .previewImport(_request()),
      );
      if (!_current) return;
      setState(() {
        for (final target in [..._departments, ..._users, ..._owners]) {
          final suggestion = result.suggestions
              .where(
                (item) =>
                    item['kind'] == target.kind &&
                    item['sourceKey'] == target.key,
              )
              .firstOrNull;
          target.targetId = suggestion?['targetId'] as String?;
          target.targetLabel = suggestion?['label'] as String?;
        }
        _initialized = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _boundaryFailed = isSessionBoundaryError(error);
          _error = permissionTransferError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(VoidCallback change) => setState(() {
    change();
    _preview = null;
    _confirmed.clear();
    _mappingConfirmed = false;
    _error = null;
  });

  Future<void> _pick(_Target target) async {
    if (!_current || _loading || _applying) return;
    try {
      final scope = await _scope;
      if (!mounted || !_current) return;
      if (target.kind == 'department') {
        final tree = await scope.run(
          ref.read(adminRepositoryProvider).departmentTree,
        );
        if (!mounted || !_current) return;
        final chosen = await showUtenDepartmentPickerPanel(
          context,
          tree: tree,
          selectablePredicate: (_) => true,
        );
        if (!_current || chosen == null || chosen.isEmpty) return;
        _edit(() {
          target.targetId = chosen.single.id;
          target.targetLabel = chosen.single.fullPath;
        });
      } else {
        final chosen = await showUtenDepartmentEmployeePicker(
          context,
          ref,
          title: target.kind == 'user' ? '选择接收权限的员工' : '选择数据归属员工',
          statuses: target.kind == 'user'
              ? const {'active', 'probation', 'onLeave'}
              : const {'active', 'probation', 'onLeave', 'resigned'},
        );
        if (!mounted || !_current || chosen == null) return;
        if (target.kind == 'owner') {
          _edit(() {
            target.targetId = chosen.id;
            target.targetLabel = chosen.displayName;
          });
        } else {
          final account = await scope.run(
            () => ref.read(adminRepositoryProvider).userByEmployeeId(chosen.id),
          );
          if (!mounted || !_current) return;
          if (!account.authorizationGrantAllowed) {
            context.appError(
              adminAuthorizationRestrictionText(context, account),
            );
            return;
          }
          _edit(() {
            target.targetId = account.id;
            target.targetLabel =
                '${chosen.displayName} · ${account.loginAccount}';
          });
        }
      }
    } catch (error) {
      if (mounted && _current) context.appError(permissionTransferError(error));
    }
  }

  Future<void> _loadPreview() async {
    if (!_current || !_mappingConfirmed) return;
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
      _confirmed.clear();
    });
    try {
      final scope = await _scope;
      final preview = await scope.run(
        () => ref
            .read(permissionConfigurationRepositoryProvider)
            .previewImport(_request()),
      );
      if (_current) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(() {
          _boundaryFailed = isSessionBoundaryError(error);
          _error = permissionTransferError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply() async {
    final preview = _preview;
    if (!_current ||
        !_mappingConfirmed ||
        _applying ||
        _uncertain ||
        _boundaryFailed ||
        preview == null ||
        !preview.canApply ||
        !preview.confirmedBy(_confirmed)) {
      return;
    }
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final scope = await _scope;
      await scope.run(
        () => ref
            .read(permissionConfigurationRepositoryProvider)
            .importConfiguration(_request(), preview, _confirmed),
      );
      if (mounted && _current) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _boundaryFailed = isSessionBoundaryError(error);
          _uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          _error = _uncertain
              ? '请求结果尚未确认，请关闭窗口刷新并核对权限，暂勿重复导入。'
              : permissionTransferError(error);
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Widget _targets(
    String title,
    List<_Target> targets, {
    bool selectable = true,
  }) {
    final selected = targets.where((target) => target.selected).toList();
    final matched = selected.where((target) => target.targetId != null).length;
    final enabled =
        _current && !_loading && !_applying && !_uncertain && !_boundaryFailed;
    return ExpansionTile(
      key: ValueKey('import-targets-${targets.firstOrNull?.kind ?? title}'),
      tilePadding: EdgeInsets.zero,
      title: Text('$title · 已匹配 $matched / ${selected.length}'),
      subtitle: matched == selected.length
          ? null
          : Text(
              '有未匹配项目，请展开选择目标或取消该项目',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
      children: [
        if (selectable)
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: UtenSpacing.s8,
              children: [
                TextButton(
                  onPressed: enabled
                      ? () => _edit(() {
                          for (final item in targets) {
                            item.selected = item.restorable;
                          }
                        })
                      : null,
                  child: const Text('全部选择'),
                ),
                TextButton(
                  onPressed: enabled
                      ? () => _edit(() {
                          for (final item in targets) {
                            item.selected = false;
                          }
                        })
                      : null,
                  child: const Text('取消选择'),
                ),
              ],
            ),
          ),
        for (final target in targets)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (selectable)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(target.label),
                    subtitle: !target.restorable
                        ? Text(target.reason ?? '设置已保存在备份中，该账号当前不允许恢复权限')
                        : null,
                    value: target.selected,
                    onChanged: enabled && target.restorable
                        ? (value) =>
                              _edit(() => target.selected = value == true)
                        : null,
                  )
                else
                  Text(target.label),
                if (target.selected)
                  TextButton.icon(
                    key: ValueKey('map-${target.kind}-${target.key}'),
                    onPressed: enabled ? () => _pick(target) : null,
                    icon: Icon(
                      target.targetId == null
                          ? Icons.person_search_outlined
                          : Icons.swap_horiz,
                    ),
                    label: Text(
                      target.targetId == null
                          ? '未匹配 · 选择目标'
                          : '导入到：${target.targetLabel ?? target.targetId}',
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    final enabled =
        _current && !_loading && !_applying && !_uncertain && !_boundaryFailed;
    final requiredOwners = _requiredOwners;
    return PopScope(
      canPop: !_applying,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _uncertain && _current) {
          refreshPermissionConfiguration(ref);
        }
      },
      child: UtenAlertDialog(
        maxWidth: 860,
        title: const Text('导入权限设置'),
        content: SizedBox(
          width: 800,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '备份包含 ${_departments.length} 个部门、${_users.length} 位员工和 ${widget.configuration.baseline.length} 项全员基础权限。',
              ),
              const SizedBox(height: UtenSpacing.s8),
              const Text(
                '核对本次接收权限的部门和人员。编号、工号相同的项目已预选；未建立的部门或账号需先创建，也可以手动选择目标。',
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (_users.any((target) => !target.restorable))
                Text(
                  '其中 ${_users.where((target) => !target.restorable).length} 位员工的设置仅作备份留存，展开个人权限可查看原因。',
                ),
              const Text(
                '恢复备份中的部门与个人授权规则，并按目标员工的部门继承情况补齐差异。备份中的负责人委派由本次管理员重新确认授权。',
              ),
              if (!_current)
                const Text('登录身份或服务器已变化，请关闭后重新操作。')
              else ...[
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_initialized) ...[
                  if (widget.configuration.exportScope != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: UtenSpacing.s8),
                      child: Text('这是单项权限文件，仅导入文件声明的范围。'),
                    ),
                  if (widget.configuration.includesBaseline)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('导入全员基础包'),
                      subtitle: const Text('影响所有在职员工'),
                      value: _baseline,
                      onChanged: enabled
                          ? (value) => _edit(() => _baseline = value == true)
                          : null,
                    ),
                  _targets('部门权限', _departments),
                  _targets('个人操作权限', _users),
                  if (widget.configuration.includesDataScopes)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('同时导入所选员工的可查看数据范围'),
                      value: _dataScopes,
                      onChanged: enabled
                          ? (value) => _edit(() => _dataScopes = value == true)
                          : null,
                    ),
                  if (_dataScopes && requiredOwners.isNotEmpty)
                    _targets(
                      '数据归属员工',
                      _owners
                          .where((item) => requiredOwners.contains(item.key))
                          .toList(),
                      selectable: false,
                    ),
                  CheckboxListTile(
                    key: const ValueKey('confirm-permission-import-mapping'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('已核对本次导入范围与接收人员、部门'),
                    value: _mappingConfirmed,
                    onChanged: enabled
                        ? (value) => setState(() {
                            _mappingConfirmed = value == true;
                            if (!_mappingConfirmed) {
                              _preview = null;
                              _confirmed.clear();
                            }
                          })
                        : null,
                  ),
                  if (_preview != null)
                    PermissionTransferPreviewDetails(
                      preview: _preview!,
                      confirmations: _confirmed,
                      enabled: enabled,
                      onConfirmationChanged: (key, checked) => setState(() {
                        checked ? _confirmed.add(key) : _confirmed.remove(key);
                      }),
                    ),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _applying
                ? null
                : () {
                    Navigator.of(context).pop(false);
                  },
            child: const Text('取消'),
          ),
          if (!_initialized && !_loading && _current && !_boundaryFailed)
            TextButton(onPressed: _suggest, child: const Text('重新读取')),
          UtenButton(
            key: const ValueKey('preview-permission-import'),
            type: UtenButtonType.secondary,
            onPressed: enabled && _mappingConfirmed ? _loadPreview : null,
            child: const Text('预览变更'),
          ),
          UtenButton(
            key: const ValueKey('confirm-permission-import'),
            isLoading: _applying,
            onPressed:
                enabled &&
                    _mappingConfirmed &&
                    _preview?.canApply == true &&
                    _preview!.confirmedBy(_confirmed)
                ? _apply
                : null,
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
  }
}
