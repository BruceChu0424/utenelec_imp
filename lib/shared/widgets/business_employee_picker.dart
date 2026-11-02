import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/inputs/uten_employee_picker.dart';
import '../../components/inputs/uten_employee_picker_access.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../models/department_node.dart';
import '../models/employee_reference.dart';
import '../repositories/employee_reference_repository.dart';

/// Business reference selection shares the Uten panel, not the HR roster API.
/// Its purpose authorizes candidates, department hierarchy and label lookup.
class BusinessEmployeePicker extends ConsumerStatefulWidget {
  const BusinessEmployeePicker({
    super.key,
    required this.purpose,
    required this.selectedId,
    required this.label,
    required this.onChanged,
    this.initial,
    this.onResolved,
    this.departmentId,
    this.departmentCode,
    this.departmentName,
    this.statuses,
    this.enabled = true,
    this.required = false,
  });

  final EmployeeReferencePurpose purpose;
  final String? selectedId;
  final String label;
  final UtenEmployeePickerItem? initial;
  final ValueChanged<UtenEmployeePickerItem?> onChanged;
  final ValueChanged<UtenEmployeePickerItem>? onResolved;
  final String? departmentId;
  final String? departmentCode;
  final String? departmentName;
  final Set<String>? statuses;
  final bool enabled;
  final bool required;

  @override
  ConsumerState<BusinessEmployeePicker> createState() =>
      _BusinessEmployeePickerState();
}

class _BusinessEmployeePickerState extends ConsumerState<BusinessEmployeePicker>
    with EmployeePickerAccessState<BusinessEmployeePicker> {
  UtenEmployeePickerItem? _resolved;
  Object? _lookupError;
  Future<List<DepartmentNode>>? _departments;
  var _generation = 0;
  var _started = false;
  var _invalidated = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _resolved = widget.initial;
      unawaited(_resolveSelected());
    }
  }

  @override
  void didUpdateWidget(BusinessEmployeePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId ||
        oldWidget.purpose != widget.purpose ||
        oldWidget.departmentId != widget.departmentId ||
        oldWidget.departmentCode != widget.departmentCode ||
        oldWidget.enabled != widget.enabled ||
        !setEquals(oldWidget.statuses, widget.statuses)) {
      _generation++;
      _departments = null;
      _resolved = widget.initial;
      _lookupError = null;
      unawaited(_resolveSelected());
    }
  }

  @override
  void onPickerAccessInvalidated() {
    _generation++;
    _invalidated = true;
    _departments = null;
    _resolved = null;
    _lookupError = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    final ticket = pickerAccess.capture();
    final generation = _generation;
    final scope = await ref
        .read(apiClientProvider)
        .captureRequestScope(
          isCurrent: () =>
              mounted &&
              !_invalidated &&
              generation == _generation &&
              ticket.isCurrent,
        );
    final result = await scope.run(action);
    scope.checkCurrent();
    return result;
  }

  Future<void> _resolveSelected() async {
    final id = widget.selectedId;
    if (id == null || id.isEmpty || _invalidated || !widget.enabled) return;
    final generation = _generation;
    final repository = ref.read(employeeReferenceRepositoryProvider);
    try {
      final values = await _read(
        () => repository.byIds([id], purpose: widget.purpose),
      );
      if (!mounted || generation != _generation || _invalidated) return;
      final value = values.where((value) => value.id == id).firstOrNull;
      if (value == null) {
        setState(
          () => _lookupError = ApiException(
            'REFERENCE_NOT_FOUND',
            '原人员目前不可读取，已保留原记录，请核对人员',
          ),
        );
        return;
      }
      final item = value.toPickerItem();
      setState(() {
        _resolved = item;
        _lookupError = null;
      });
      widget.onResolved?.call(item);
    } on Object catch (error) {
      if (!mounted ||
          generation != _generation ||
          _invalidated ||
          isSessionBoundaryError(error)) {
        return;
      }
      setState(() => _lookupError = error);
    }
  }

  Future<List<DepartmentNode>> _loadDepartments() async {
    final repository = ref.read(employeeReferenceRepositoryProvider);
    final pending = _departments ??= _read(
      () => repository.departments(widget.purpose),
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(pending, _departments)) _departments = null;
      rethrow;
    }
  }

  Future<List<UtenEmployeePickerItem>> _loadCandidates(String? keyword) async {
    // Disabled detail fields retain their recorded label without requesting a
    // new write-purpose candidate list just to enhance its display.
    if (!widget.enabled) return const [];
    final ticket = pickerAccess.capture();
    final generation = _generation;
    final repository = ref.read(employeeReferenceRepositoryProvider);
    final purpose = widget.purpose;
    final query = keyword?.trim() ?? '';
    return _read(() async {
      String? departmentId;
      if (query.isEmpty) {
        departmentId = widget.departmentId;
        if (departmentId == null && widget.departmentCode != null) {
          final code = widget.departmentCode!;
          final tree = await _loadDepartments();
          DepartmentNode? find(List<DepartmentNode> nodes) {
            for (final node in nodes) {
              if (node.code == code) return node;
              final child = find(node.children);
              if (child != null) return child;
            }
            return null;
          }

          departmentId = find(tree)?.id;
          if (departmentId == null) {
            throw ApiException(
              'REFERENCE_DEPARTMENT_NOT_FOUND',
              '未找到默认部门，请输入姓名或工号搜索',
            );
          }
        }
      }
      final rows = await repository.listPickerCandidates(
        purpose: purpose,
        search: query.isEmpty ? null : query,
        statuses: widget.statuses,
        departmentId: departmentId,
        includeSubtree: query.isEmpty,
        isCurrent: () =>
            mounted &&
            !_invalidated &&
            generation == _generation &&
            ticket.isCurrent,
      );
      return rows.map((row) => row.toPickerItem()).toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      UtenEmployeePicker(
        label: widget.label,
        hint: '请选择${widget.label}',
        sheetTitle: '选择${widget.label}',
        required: widget.required,
        enabled: widget.enabled && !_invalidated,
        initial: _invalidated ? null : _resolved,
        candidateScopeKey: (
          widget.purpose,
          widget.departmentId,
          widget.departmentCode,
        ),
        departmentName: widget.departmentName,
        departmentTreeLoader: _loadDepartments,
        presentation: UtenEmployeePickerPresentation.businessReference,
        loader: _loadCandidates,
        onChanged: (value) {
          setState(() {
            _resolved = value;
            _lookupError = null;
          });
          widget.onChanged(value);
        },
      ),
      if (_lookupError case final error?)
        Row(
          children: [
            Expanded(
              child: Text(
                error is ApiException ? error.message : '人员资料读取失败，请重试',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            IconButton(
              onPressed: widget.enabled && !_invalidated
                  ? _resolveSelected
                  : null,
              tooltip: '重新读取人员',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
    ],
  );
}
