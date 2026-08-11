// 员工调岗对话框（真实后端）
// 提交：POST /api/org/employees/{id}/transfer；后端写 transfer 任职记录并更新部门/岗位。
// 成功返回 true（调用方负责刷新详情）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/position.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../department/widgets/uten_position_picker.dart';
import '../repositories/employee_repository.dart';

/// 弹出调岗对话框；成功提交并返回 true，取消/失败返回 false。
Future<bool> showEmployeeTransferDialog(
  BuildContext context, {
  required String employeeId,
  String? currentDepartmentId,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _EmployeeTransferDialog(
      employeeId: employeeId,
      currentDepartmentId: currentDepartmentId,
    ),
  ).then((v) => v ?? false);
}

class _EmployeeTransferDialog extends ConsumerStatefulWidget {
  const _EmployeeTransferDialog({
    required this.employeeId,
    this.currentDepartmentId,
  });

  final String employeeId;
  final String? currentDepartmentId;

  @override
  ConsumerState<_EmployeeTransferDialog> createState() =>
      _EmployeeTransferDialogState();
}

class _EmployeeTransferDialogState
    extends ConsumerState<_EmployeeTransferDialog> {
  List<DeptSelection> _deptSelection = const [];
  Position? _position;
  DateTime _date = ChinaDateTime.today();
  final _remark = TextEditingController();
  bool _submitting = false;

  String? get _departmentId =>
      _deptSelection.isEmpty ? null : _deptSelection.first.id;

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: ChinaDateTime.today(),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final deptId = _departmentId;
    if (deptId == null) {
      context.appError(l10n.employeeEditRequired);
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(employeeRepositoryProvider).transfer(widget.employeeId, {
        'toDepartmentId': deptId,
        if (_position != null) 'toPositionId': _position!.id,
        'effectiveDate': DateFormat('yyyy-MM-dd').format(_date),
        if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      });
      if (!mounted) return;
      context.appSuccess(l10n.employeeTransferSuccess);
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.employeeOffboardLoadFailed);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.employeeTransferTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDepartmentPicker(
              mode: UtenDepartmentPickerMode.single,
              label: l10n.employeeFieldDepartment,
              initialSelection: _deptSelection,
              onChanged: (sel) => setState(() {
                _deptSelection = sel;
                _position = null;
              }),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenPositionPicker(
              departmentId: _departmentId,
              value: _position,
              label: l10n.employeeFieldPosition,
              onChanged: (p) => setState(() => _position = p),
            ),
            const SizedBox(height: UtenSpacing.s12),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: l10n.employeeTransferFieldDate,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                child: Text(DateFormat('yyyy-MM-dd').format(_date)),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _remark,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: l10n.employeeTransferFieldRemark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
