import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';
import '../providers/admin_providers.dart';
import '../repositories/permission_template_repository.dart';
import 'admin_permission_transfer_actions.dart';
import 'permission_action_badge.dart';
import 'permission_catalog_browser.dart';
import 'permission_transfer_preview.dart';

/// Employees and departments share one preview, confirmation and commit flow.
/// IDs are copied at entry, so later list filtering cannot change the targets.
Future<bool?> showPermissionBatchDialog(
  BuildContext context, {
  required bool templateMode,
  List<String> userIds = const [],
  List<String> departmentIds = const [],
  String? targetLabel,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PermissionBatchDialog(
    templateMode: templateMode,
    userIds: List.unmodifiable(userIds),
    departmentIds: List.unmodifiable(departmentIds),
    targetLabel: targetLabel,
  ),
);

class PermissionBatchDialog extends ConsumerStatefulWidget {
  const PermissionBatchDialog({
    super.key,
    required this.templateMode,
    required this.userIds,
    required this.departmentIds,
    this.targetLabel,
  });
  final bool templateMode;
  final List<String> userIds;
  final List<String> departmentIds;
  final String? targetLabel;
  @override
  ConsumerState<PermissionBatchDialog> createState() => _PermissionBatchState();
}

class _PermissionBatchState extends ConsumerState<PermissionBatchDialog> {
  late final _boundary = ref.read(sensitiveReadBoundaryProvider);
  PermissionTemplate? _template;
  bool _merge = true;
  bool _grant = true;
  bool _busy = false;
  bool _committing = false;
  bool _uncertain = false;
  String? _error;
  final _codes = <String>{};
  final _confirmed = <String>{};
  PermissionTransferPreview? _preview;
  bool get _current =>
      mounted &&
      _boundary == ref.read(sensitiveReadBoundaryProvider) &&
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);
  bool get _enabled => _current && !_busy && !_uncertain;
  String get _path => widget.templateMode
      ? '/admin/permission-templates/apply'
      : '/admin/permissions/batch';
  Map<String, dynamic> get _request => {
    'userIds': widget.userIds,
    'departmentIds': widget.departmentIds,
    if (widget.templateMode) ...{
      'templateId': _template!.id,
      'templateVersion': _template!.version,
      'mode': _merge ? 'MERGE' : 'REPLACE',
    } else ...{
      'grants': _grant ? (_codes.toList()..sort()) : <String>[],
      'revokes': _grant ? <String>[] : (_codes.toList()..sort()),
    },
  };
  void _reset() {
    _preview = null;
    _confirmed.clear();
    _error = null;
  }

  void _selectCodes(Iterable<String> codes, bool selected) {
    if (!_enabled) return;
    setState(() {
      selected ? _codes.addAll(codes) : _codes.removeAll(codes);
      _reset();
    });
  }

  Future<void> _execute(bool commit) async {
    if (!_enabled ||
        (widget.templateMode ? _template == null : _codes.isEmpty)) {
      return;
    }
    final preview = _preview;
    if (commit &&
        (preview == null ||
            !preview.canApply ||
            !preview.confirmedBy(_confirmed))) {
      return;
    }
    final request = _request;
    setState(() {
      _busy = true;
      _committing = commit;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final scope = await api.captureRequestScope(isCurrent: () => _current);
      Map<String, dynamic> response;
      if (widget.templateMode &&
          widget.userIds.length == 1 &&
          widget.departmentIds.isEmpty) {
        final repository = ref.read(permissionTemplateRepositoryProvider);
        if (commit) {
          await scope.run(
            () => repository.apply(
              widget.userIds.single,
              _template!,
              _merge,
              preview!,
              _confirmed,
            ),
          );
          response = const {};
        } else {
          final result = await scope.run(
            () => repository.preview(widget.userIds.single, _template!, _merge),
          );
          if (!mounted || !_current) return;
          setState(() {
            _preview = result;
            _confirmed.clear();
          });
          return;
        }
      } else {
        response = await scope.run(
          () => api.post(
            commit ? _path : '$_path/preview',
            body: commit
                ? {
                    'request': request,
                    'expectedFingerprint': preview!.fingerprint,
                    'sensitiveConfirmations': _confirmed.toList()..sort(),
                  }
                : request,
          ),
        );
      }
      if (!mounted || !_current) return;
      if (commit) {
        refreshPermissionConfiguration(ref);
        Navigator.pop(context, true);
      } else {
        setState(() {
          _preview = PermissionTransferPreview.fromJson(response);
          _confirmed.clear();
        });
      }
    } catch (error) {
      if (!mounted || !_current) return;
      setState(() {
        _uncertain =
            commit &&
            (error is! ApiException ||
                error.httpStatus == null ||
                error.httpStatus! >= 500);
        _error = _uncertain
            ? '请求结果尚未确认。请关闭后刷新目标权限核对，避免重复提交。'
            : error is ApiException
            ? error.message
            : '权限预览失败，请稍后重试';
        _preview = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    final count = widget.userIds.length + widget.departmentIds.length;
    return PopScope(
      canPop: !_committing,
      child: UtenAlertDialog(
        maxWidth: 860,
        title: Text(widget.templateMode ? '应用权限模板' : '批量设置权限'),
        content: SizedBox(
          width: 780,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.targetLabel ??
                    '已选 ${widget.userIds.length} 名员工、${widget.departmentIds.length} 个部门',
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                widget.templateMode
                    ? '应用后建立关联，模板修改会同步生效；个人取消继续优先。'
                    : '仅调整本次勾选的权限，其余设置和模板关联保持。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (widget.templateMode)
                ..._templateFields()
              else
                ..._permissionFields(),
              if (!_current) const Text('账号或连接已变化，请关闭后重新操作'),
              if (count == 0 || count > 500) const Text('请选择 1 至 500 个对象后重新打开'),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_preview != null)
                PermissionTransferPreviewDetails(
                  preview: _preview!,
                  confirmations: _confirmed,
                  enabled: _enabled,
                  onConfirmationChanged: (key, selected) => setState(() {
                    selected ? _confirmed.add(key) : _confirmed.remove(key);
                  }),
                ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _committing
                ? null
                : () {
                    if (_uncertain && _current) {
                      refreshPermissionConfiguration(ref);
                    }
                    Navigator.pop(context);
                  },
            child: const Text('关闭'),
          ),
          UtenButton(
            type: UtenButtonType.secondary,
            isLoading: _busy && !_committing,
            onPressed:
                _enabled &&
                    count > 0 &&
                    count <= 500 &&
                    (widget.templateMode
                        ? _template != null
                        : _codes.isNotEmpty)
                ? () => _execute(false)
                : null,
            child: const Text('预览变更'),
          ),
          UtenButton(
            key: const ValueKey('confirm-apply-permission-template'),
            isLoading: _committing,
            onPressed:
                _enabled &&
                    _preview?.canApply == true &&
                    _preview!.confirmedBy(_confirmed)
                ? () => _execute(true)
                : null,
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
  }

  List<Widget> _templateFields() => [
    ref
        .watch(permissionTemplatesProvider)
        .when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(permissionTemplatesProvider),
            child: const Text('模板加载失败，点击重试'),
          ),
          data: (items) => items.isEmpty
              ? const Text('请先在权限模板中建立模板')
              : UtenDropdownScrollScope(
                  nativeDropdown: true,
                  child: DropdownButtonFormField<PermissionTemplate>(
                    key: ValueKey(
                      items.map((t) => '${t.id}:${t.version}').join(','),
                    ),
                    isExpanded: true,
                    initialValue: items
                        .where((t) => t == _template)
                        .firstOrNull,
                    decoration: const InputDecoration(labelText: '选择权限模板'),
                    items: [
                      for (final t in items)
                        DropdownMenuItem(value: t, child: Text(t.name)),
                    ],
                    onChanged: _enabled
                        ? (value) => setState(() {
                            _template = value;
                            _reset();
                          })
                        : null,
                  ),
                ),
        ),
    const SizedBox(height: UtenSpacing.s8),
    UtenSegmentRow<bool>(
      selected: {_merge},
      segments: const [
        ButtonSegment(value: true, label: Text('合并现有权限')),
        ButtonSegment(value: false, label: Text('替换直接设置')),
      ],
      onSelectionChanged: _enabled
          ? (values) => setState(() {
              _merge = values.single;
              _reset();
            })
          : null,
    ),
    const SizedBox(height: UtenSpacing.s8),
    Text(_merge ? '保留手工设置并关联新模板。' : '按预览替换所选对象的直接设置；基础包、上级部门和负责人授权仍按来源生效。'),
  ];
  List<Widget> _permissionFields() => [
    UtenSegmentRow<bool>(
      selected: {_grant},
      segments: const [
        ButtonSegment(value: true, label: Text('授权所选权限')),
        ButtonSegment(value: false, label: Text('取消所选权限')),
      ],
      onSelectionChanged: _enabled
          ? (values) => setState(() {
              _grant = values.single;
              _codes.clear();
              _reset();
            })
          : null,
    ),
    const SizedBox(height: UtenSpacing.s8),
    ref
        .watch(permissionCatalogProvider)
        .when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(permissionCatalogProvider),
            child: const Text('权限目录加载失败，点击重试'),
          ),
          data: (groups) => PermissionCatalogBrowser(
            groups: groups,
            isEnabled: (p) => _codes.contains(p.code),
            enabledFilterLabel: '已选',
            disabledFilterLabel: '未选',
            enableAllLabel: '选择全部普通权限',
            disableAllLabel: '清空选择',
            enableModuleLabel: '选择本模块普通权限',
            enableGroupLabel: '选择本组普通权限',
            disableModuleLabel: '取消本模块选择',
            disableGroupLabel: '取消本组选择',
            onGrantScope: _enabled
                ? (scope) => _selectCodes([
                    for (final group in groups)
                      if ((scope.module == null ||
                              group.module == scope.module) &&
                          (scope.category == null ||
                              group.category == scope.category))
                        for (final p in group.permissions)
                          if (!_grant || p.grantPolicy.bulkEligible) p.code,
                  ], true)
                : null,
            onDisableGroup: _enabled
                ? (items) => _selectCodes(items.map((p) => p.code), false)
                : null,
            onDisableAll: _enabled
                ? (_) => _selectCodes(_codes.toList(), false)
                : null,
            itemBuilder: (context, permission) => CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: PermissionTitleBlock(
                name: permission.name,
                actionType: permission.actionType,
                description: permission.description,
                grantPolicy: permission.grantPolicy,
                sensitivity: permission.sensitivity,
              ),
              value: _codes.contains(permission.code),
              onChanged:
                  _enabled &&
                      (!_grant || permission.grantPolicy.individuallyGrantable)
                  ? (value) => _selectCodes([permission.code], value == true)
                  : null,
            ),
          ),
        ),
  ];
}
