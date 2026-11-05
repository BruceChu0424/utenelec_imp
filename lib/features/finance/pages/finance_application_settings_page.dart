import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_applications_page.dart';

class FinanceApplicationSettingsPage extends ConsumerStatefulWidget {
  const FinanceApplicationSettingsPage({super.key});
  @override
  ConsumerState<FinanceApplicationSettingsPage> createState() =>
      _SettingsState();
}

class _SettingsState extends ConsumerState<FinanceApplicationSettingsPage> {
  Map<String, dynamic> _data = {}, _refs = {};
  String? _error;
  bool _busy = true;
  int _epoch = -1, _request = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ref.read(exportContextEpochProvider), request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
      _epoch = epoch;
      _data = {};
    });
    try {
      final api = ref.read(apiClientProvider);
      final rows = await Future.wait([
        api.get('$financeApplicationsApi/settings'),
        api.get('$financeApplicationsApi/references'),
      ]);
      if (!mounted ||
          epoch != ref.read(exportContextEpochProvider) ||
          request != _request) {
        return;
      }
      setState(() {
        _data = rows[0];
        _refs = rows[1];
        _busy = false;
      });
    } catch (e) {
      if (mounted &&
          epoch == ref.read(exportContextEpochProvider) &&
          request == _request) {
        setState(() {
          _error = humanErrorMessage(e) ?? '流程设置未读取完成';
          _busy = false;
        });
      }
    }
  }

  Future<void> _edit({
    Map<String, dynamic>? role,
    bool settings = false,
  }) async {
    final epoch = _epoch;
    final updated = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 640,
          child: _SettingsEditor(
            data: _data,
            references: _refs,
            role: role,
            settings: settings,
          ),
        ),
      ),
    );
    if (updated == true &&
        mounted &&
        epoch == ref.read(exportContextEpochProvider)) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == _epoch;
    final rows = current
        ? financeApplicationRows(_data['roles'])
        : <Map<String, dynamic>>[];
    final definitions = {
      for (final r in financeApplicationRows(_data['roleDefinitions']))
        r['key']: r['label'],
    };
    return Scaffold(
      appBar: UtenAppBar(
        title: '各部门申请流程 · 流程设置',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : _load,
            child: const Text('刷新'),
          ),
        ],
      ),
      body: UtenContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    current && _data['enabled'] == true
                        ? '新申请流程已启用'
                        : '新申请流程未启用',
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: current && !_busy
                        ? () => _edit(settings: true)
                        : null,
                    child: const Text('启用/关闭'),
                  ),
                  UtenButton(
                    onPressed: current && !_busy ? () => _edit(role: {}) : null,
                    child: const Text('新增岗位人员'),
                  ),
                ],
              ),
            ),
            const Text(
              '原图人名是岗位说明；请选择真实在职员工及其启用账号。启用后只接新申请，历史已审批单不退回重审。部门负责人优先使用明确代理配置，否则沿组织架构负责人。',
            ),
            if (!current) const Text('身份或权限已变化，请刷新。'),
            Expanded(
              child: MasterDataTableView<Map<String, dynamic>>(
                columns: [
                  MasterColumnDef(
                    key: 'roleKey',
                    label: '原流程岗位',
                    width: 250,
                    value: (r) => definitions[r['roleKey']]?.toString() ?? '',
                    columnSearchEnabled: false,
                  ),
                  financeApplicationColumn('departmentName', '部门', 170),
                  financeApplicationColumn('employeeName', '实际办理人员', 180),
                  financeApplicationColumn('sourceReference', '指派依据', 320),
                ],
                items: rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                isLoading: _busy,
                error: _error,
                onRetry: _load,
                onRowTap: (r) => _edit(role: r),
                showPaginationControls: false,
                headerFilterScopeDescription: '本页原流程全部岗位配置，点击一行编辑',
                rowKeyOf: (r) => r['id'].toString(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsEditor extends ConsumerStatefulWidget {
  const _SettingsEditor({
    required this.data,
    required this.references,
    this.role,
    required this.settings,
  });
  final Map<String, dynamic> data, references;
  final Map<String, dynamic>? role;
  final bool settings;
  @override
  ConsumerState<_SettingsEditor> createState() => _SettingsEditorState();
}

class _SettingsEditorState extends ConsumerState<_SettingsEditor> {
  final _reference = TextEditingController();
  String? _role, _department, _employee;
  bool _enabled = false, _busy = false;
  late String _id;
  Map<String, dynamic>? _sent;
  late int _epoch;
  @override
  void initState() {
    super.initState();
    _epoch = ref.read(exportContextEpochProvider);
    _id = widget.role?['id']?.toString() ?? const Uuid().v4();
    _role = widget.role?['roleKey']?.toString();
    _department = widget.role?['departmentId']?.toString();
    _employee = widget.role?['employeeId']?.toString();
    _reference.text =
        (widget.settings
                ? widget.data['sourceReference']
                : widget.role?['sourceReference'])
            ?.toString() ??
        '';
    _enabled = widget.data['enabled'] == true;
  }

  Future<void> _save() async {
    if (_busy || _epoch != ref.read(exportContextEpochProvider)) return;
    setState(() => _busy = true);
    try {
      _sent ??= widget.settings
          ? {
              'expectedVersion': widget.data['version'],
              'enabled': _enabled,
              'sourceReference': _reference.text,
            }
          : {
              'id': _id,
              'expectedVersion': widget.role?['version'] ?? -1,
              'roleKey': _role,
              'departmentId': _role == 'DEPARTMENT_REVIEW' ? _department : null,
              'employeeId': _employee,
              'sourceReference': _reference.text,
            };
      await ref
          .read(apiClientProvider)
          .post(
            '$financeApplicationsApi/settings${widget.settings ? '' : '/roles'}',
            body: _sent,
          );
      if (mounted && _epoch == ref.read(exportContextEpochProvider)) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted && _epoch == ref.read(exportContextEpochProvider)) {
        context.appApiError(e, fallback: '设置结果待确认，请保留原内容并重试');
      }
    } finally {
      if (mounted && _epoch == ref.read(exportContextEpochProvider)) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == _epoch;
    final editable = current && !_busy && _sent == null;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDialogHeader(
            padding: EdgeInsets.zero,
            title: Text(
              widget.settings ? '启用/关闭原申请流程' : '明确配置原岗位人员',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            showCloseButton: true,
            onClose: _busy ? null : () => Navigator.pop(context),
          ),
          const SizedBox(height: 16),
          if (widget.settings)
            UtenDropdownField(
              label: '新申请流程',
              value: _enabled ? 'on' : 'off',
              items: const [
                UtenDropdownItem(value: 'on', label: '启用'),
                UtenDropdownItem(value: 'off', label: '关闭新申请接入'),
              ],
              enabled: editable,
              allowClear: false,
              onChanged: editable
                  ? (v) => setState(() => _enabled = v == 'on')
                  : (_) {},
            )
          else ...[
            UtenDropdownField(
              label: '原流程岗位',
              value: _role,
              items: [
                for (final r in financeApplicationRows(
                  widget.data['roleDefinitions'],
                ))
                  UtenDropdownItem(
                    value: r['key'].toString(),
                    label: r['label'].toString(),
                  ),
              ],
              enabled: editable,
              onChanged: editable ? (v) => setState(() => _role = v) : (_) {},
            ),
            const SizedBox(height: 12),
            if (_role == 'DEPARTMENT_REVIEW')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: UtenDropdownField(
                  label: '明确部门',
                  value: _department,
                  items: [
                    for (final r in financeApplicationRows(
                      widget.references['departments'],
                    ))
                      UtenDropdownItem(
                        value: r['id'].toString(),
                        label: r['name'].toString(),
                      ),
                  ],
                  enabled: editable,
                  onChanged: editable
                      ? (v) => setState(() => _department = v)
                      : (_) {},
                ),
              ),
            BusinessEmployeePicker(
              purpose: EmployeeReferencePurpose.financeApplicationReviewer,
              selectedId: _employee,
              label: '实际办理人员',
              statuses: const {'active', 'probation', 'onLeave'},
              enabled: editable,
              required: true,
              onChanged: (v) => setState(() => _employee = v?.id),
            ),
          ],
          const SizedBox(height: 12),
          UtenInput(
            label: widget.settings ? '启用/关闭依据' : '指派依据',
            controller: _reference,
            enabled: editable,
            maxLines: 3,
            required: true,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.end,
            children: [
              UtenButton(
                onPressed: current && !_busy ? _save : null,
                child: Text(_sent == null ? '保存' : '重试原设置'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
