// 员工编辑页（Phase 2）
// 文档：docs/03-页面/员工编辑页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_app_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../department/models/department.dart';
import '../../department/providers/department_providers.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';

class EmployeeEditPage extends ConsumerStatefulWidget {
  const EmployeeEditPage({super.key, required this.employeeId});
  final String employeeId;

  @override
  ConsumerState<EmployeeEditPage> createState() => _EmployeeEditPageState();
}

class _EmployeeEditPageState extends ConsumerState<EmployeeEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _phone = TextEditingController();
  final _position = TextEditingController();

  Gender _gender = Gender.male;
  EmploymentType _employmentType = EmploymentType.regular;
  EmployeeStatus _status = EmployeeStatus.active;
  String? _department;
  bool _saving = false;
  bool _loaded = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _phone.dispose();
    _position.dispose();
    super.dispose();
  }

  void _fill(Employee e) {
    if (_loaded) return;
    _name.text = e.fullName;
    _code.text = e.code;
    _phone.text = e.phone;
    _position.text = e.position;
    _gender = e.gender;
    _employmentType = e.employmentType;
    _status = e.status;
    _department = e.department;
    _loaded = true;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    setState(() => _saving = false);
    if (mounted) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.employeeEditSaved)));
      context.go('/employee/${widget.employeeId}');
    }
  }

  String _employmentTypeLabel(AppLocalizations l10n, EmploymentType t) =>
      switch (t) {
        EmploymentType.regular => l10n.employmentTypeRegular,
        EmploymentType.dispatch => l10n.employmentTypeDispatch,
        EmploymentType.intern => l10n.employmentTypeIntern,
      };

  String _statusLabel(AppLocalizations l10n, EmployeeStatus s) => switch (s) {
    EmployeeStatus.active => l10n.employeeStatusActive,
    EmployeeStatus.probation => l10n.employeeStatusProbation,
    EmployeeStatus.onLeave => l10n.employeeStatusOnLeave,
    EmployeeStatus.resigned => l10n.employeeStatusResigned,
  };

  String _genderLabel(AppLocalizations l10n, Gender g) => switch (g) {
    Gender.male => l10n.genderMale,
    Gender.female => l10n.genderFemale,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(employeeDetailProvider(widget.employeeId));
    final deptNames = ref
        .watch(departmentTreeProvider)
        .maybeWhen(
          data: (roots) => _allDeptNames(roots),
          orElse: () => const <String>[],
        );

    return Scaffold(
      appBar: UtenAppBar(title: l10n.employeeEditTitle, showBackButton: true),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.commonSave),
          ),
        ),
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Center(child: Text(l10n.employeeEditLoadFailed(e.toString()))),
        data: (e) {
          if (e == null) {
            return Center(child: Text(l10n.employeeEditNotFound));
          }
          _fill(e);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionTitle(l10n.employeeEditBasic),
                  TextFormField(
                    controller: _name,
                    decoration: _Deco(l10n.employeeFieldName),
                    validator: (v) => (v == null || v.isEmpty)
                        ? l10n.employeeEditRequired
                        : null,
                  ),
                  TextFormField(
                    controller: _code,
                    decoration: _Deco(l10n.employeeFieldCode),
                    validator: (v) => (v == null || v.isEmpty)
                        ? l10n.employeeEditRequired
                        : null,
                  ),
                  _DropdownField<Gender>(
                    label: l10n.employeeFieldGender,
                    value: _gender,
                    items: Gender.values,
                    labelOf: (g) => _genderLabel(l10n, g),
                    onChanged: (v) => setState(() => _gender = v!),
                  ),
                  TextFormField(
                    controller: _phone,
                    decoration: _Deco(l10n.employeeEditFieldPhone),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 20),
                  _SectionTitle(l10n.employeeEditOrg),
                  _DropdownField<String>(
                    label: l10n.employeeEditFieldDepartment,
                    value: _department,
                    items: deptNames,
                    labelOf: (s) => s,
                    onChanged: (v) => setState(() => _department = v),
                    validator: (v) =>
                        v == null ? l10n.employeeEditRequired : null,
                  ),
                  TextFormField(
                    controller: _position,
                    decoration: _Deco(l10n.employeeEditFieldPosition),
                  ),
                  _DropdownField<EmploymentType>(
                    label: l10n.employeeEditFieldEmploymentType,
                    value: _employmentType,
                    items: EmploymentType.values,
                    labelOf: (t) => _employmentTypeLabel(l10n, t),
                    onChanged: (v) => setState(() => _employmentType = v!),
                  ),
                  _DropdownField<EmployeeStatus>(
                    label: l10n.employeeEditFieldStatus,
                    value: _status,
                    items: EmployeeStatus.values,
                    labelOf: (s) => _statusLabel(l10n, s),
                    onChanged: (v) => setState(() => _status = v!),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<String> _allDeptNames(List<Department> roots) {
    final names = <String>[];
    void walk(List<Department> nodes) {
      for (final n in nodes) {
        names.add(n.name);
        if (n.children.isNotEmpty) walk(n.children);
      }
    }

    walk(roots);
    return names;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4, bottom: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _Deco extends InputDecoration {
  const _Deco(String label)
    : super(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      );
}

class _DropdownField<T> extends FormField<T> {
  _DropdownField({
    required String label,
    T? value,
    required List<T> items,
    required String Function(T) labelOf,
    required ValueChanged<T?> onChanged,
    super.validator,
  }) : super(
         initialValue: value,
         builder: (state) {
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
               DropdownButtonFormField<T>(
                 initialValue: value,
                 decoration: _Deco(label),
                 items: [
                   for (final it in items)
                     DropdownMenuItem(value: it, child: Text(labelOf(it))),
                 ],
                 onChanged: (v) {
                   if (v != null) onChanged(v);
                   state.didChange(v);
                 },
               ),
               if (state.hasError)
                 Padding(
                   padding: const EdgeInsets.only(top: 6, left: 12),
                   child: Text(
                     state.errorText ?? '',
                     style: const TextStyle(
                       color: Color(0xFFEF4444),
                       fontSize: 12,
                     ),
                   ),
                 ),
             ],
           );
         },
       );
}
