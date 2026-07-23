// 员工编辑页（Phase 2）
// 文档：docs/03-页面/员工编辑页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_app_bar.dart';
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存（Mock）')),
      );
      context.go('/employee/${widget.employeeId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(employeeDetailProvider(widget.employeeId));
    final deptNames = ref.watch(departmentTreeProvider).maybeWhen(
          data: (roots) => _allDeptNames(roots),
          orElse: () => const <String>[],
        );

    return Scaffold(
      appBar: const UtenAppBar(title: '编辑员工', showBackButton: true),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ),
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (e) {
          if (e == null) {
            return const Center(child: Text('员工不存在'));
          }
          _fill(e);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('基本信息'),
                  TextFormField(
                    controller: _name,
                    decoration: const _Deco('姓名'),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '必填' : null,
                  ),
                  TextFormField(
                    controller: _code,
                    decoration: const _Deco('工号'),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? '必填' : null,
                  ),
                  _DropdownField<Gender>(
                    label: '性别',
                    value: _gender,
                    items: Gender.values,
                    labelOf: (g) => g.label,
                    onChanged: (v) => setState(() => _gender = v!),
                  ),
                  TextFormField(
                    controller: _phone,
                    decoration: const _Deco('手机'),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 20),
                  const _SectionTitle('组织信息'),
                  _DropdownField<String>(
                    label: '部门',
                    value: _department,
                    items: deptNames,
                    labelOf: (s) => s,
                    onChanged: (v) => setState(() => _department = v),
                    validator: (v) => v == null ? '必填' : null,
                  ),
                  TextFormField(
                    controller: _position,
                    decoration: const _Deco('岗位'),
                  ),
                  _DropdownField<EmploymentType>(
                    label: '用工性质',
                    value: _employmentType,
                    items: EmploymentType.values,
                    labelOf: (t) => t.label,
                    onChanged: (v) => setState(() => _employmentType = v!),
                  ),
                  _DropdownField<EmployeeStatus>(
                    label: '员工状态',
                    value: _status,
                    items: EmployeeStatus.values,
                    labelOf: (s) => s.label,
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
      child: Text(text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface)),
    );
  }
}

class _Deco extends InputDecoration {
  const _Deco(String label)
      : super(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
                    child: Text(state.errorText ?? '',
                        style:
                            const TextStyle(color: Color(0xFFEF4444), fontSize: 12)),
                  ),
              ],
            );
          },
        );
}
