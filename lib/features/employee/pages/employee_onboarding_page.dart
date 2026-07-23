// 入职办理页（真实后端）：单表单分组提交 → 后端原子建 employee+敏感+薪资+合同+轨迹+账号。
// 账号 = 工号；初始密码 = 身份证后六位（首登强制改）。
// 文档：docs/03-页面/入职流程页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

class EmployeeOnboardingPage extends ConsumerStatefulWidget {
  const EmployeeOnboardingPage({super.key});

  @override
  ConsumerState<EmployeeOnboardingPage> createState() =>
      _EmployeeOnboardingPageState();
}

class _EmployeeOnboardingPageState
    extends ConsumerState<EmployeeOnboardingPage> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _idNumber = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _hireDate = TextEditingController();
  final _baseSalary = TextEditingController();
  final _bankAccount = TextEditingController();
  final _bankBranch = TextEditingController();

  // Backend option codes are unchanged; labels come from l10n at build time.
  static const _idTypeCodes = ['身份证', '护照', '港澳台通行证', '其他'];
  static const _employmentTypeCodes = [
    'regular',
    'dispatch',
    'intern',
    'outsource',
  ];
  static const _statusCodes = ['active', 'probation', 'onLeave'];

  String _idType = '身份证';
  String _employmentType = 'regular';
  String _status = 'active';
  String? _departmentId;
  List<DepartmentNode> _depts = const [];
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDepts());
  }

  @override
  void dispose() {
    for (final c in [
      _code,
      _name,
      _idNumber,
      _phone,
      _email,
      _hireDate,
      _baseSalary,
      _bankAccount,
      _bankBranch,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDepts() async {
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _depts = _flatten(tree);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<DepartmentNode> _flatten(List<DepartmentNode> tree) {
    final out = <DepartmentNode>[];
    void walk(List<DepartmentNode> nodes) {
      for (final n in nodes) {
        out.add(n);
        walk(n.children);
      }
    }

    walk(tree);
    return out;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d != null) {
      _hireDate.text = DateFormat('yyyy-MM-dd').format(d);
    }
  }

  String _idTypeLabel(AppLocalizations l10n, String code) => switch (code) {
    '身份证' => l10n.idTypeIdCard,
    '护照' => l10n.idTypePassport,
    '港澳台通行证' => l10n.idTypeHmtPermit,
    '其他' => l10n.idTypeOther,
    _ => code,
  };

  String _employmentTypeLabel(AppLocalizations l10n, String code) =>
      switch (code) {
        'regular' => l10n.employmentTypeRegular,
        'dispatch' => l10n.employmentTypeDispatch,
        'intern' => l10n.employmentTypeIntern,
        'outsource' => l10n.employmentTypeOutsource,
        _ => code,
      };

  String _statusLabel(AppLocalizations l10n, String code) => switch (code) {
    'active' => l10n.employeeStatusActive,
    'probation' => l10n.employeeStatusProbation,
    'onLeave' => l10n.employeeStatusOnLeave,
    _ => code,
  };

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final l10n = AppLocalizations.of(context);
    try {
      final profile = <String, dynamic>{
        'code': _code.text.trim(),
        'fullName': _name.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'phone': _phone.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
      };
      final employment = <String, dynamic>{
        'departmentId': _departmentId,
        'hireDate': _hireDate.text.trim().isEmpty
            ? DateTime.now().toIso8601String().substring(0, 10)
            : _hireDate.text.trim(),
        'employmentType': _employmentType,
        'status': _status,
      };
      Map<String, dynamic>? compensation;
      if (_baseSalary.text.trim().isNotEmpty ||
          _bankAccount.text.trim().isNotEmpty) {
        compensation = {
          if (_baseSalary.text.trim().isNotEmpty)
            'baseSalary': _baseSalary.text.trim(),
          if (_bankAccount.text.trim().isNotEmpty)
            'bankAccount': _bankAccount.text.trim(),
          if (_bankBranch.text.trim().isNotEmpty)
            'bankBranch': _bankBranch.text.trim(),
        };
      }
      await ref
          .read(employeeRepositoryProvider)
          .create(
            EmployeeOnboardingInput(
              profile: profile,
              employment: employment,
              compensation: compensation,
            ),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.employeeOnboardSuccess)));
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.employeeOnboardSubmitFailed)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.employeeOnboardTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _group(theme, l10n.employeeOnboardGroupProfile, [
                    _text(
                      _code,
                      '${l10n.employeeFieldCode}*',
                      l10n.employeeOnboardHintCode,
                      validator: (v) => _req(l10n, v, l10n.employeeFieldCode),
                    ),
                    _text(
                      _name,
                      '${l10n.employeeFieldName}*',
                      l10n.employeeOnboardHintName,
                      validator: (v) => _req(l10n, v, l10n.employeeFieldName),
                    ),
                    DropdownButtonFormField<String>(
                      value: _idType,
                      decoration: InputDecoration(
                        labelText: '${l10n.employeeFieldIdType}*',
                      ),
                      items: _idTypeCodes
                          .map(
                            (c) => DropdownMenuItem(
                              value: c,
                              child: Text(_idTypeLabel(l10n, c)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _idType = v ?? _idType),
                    ),
                    _text(
                      _idNumber,
                      '${l10n.employeeFieldIdNumber}*',
                      l10n.employeeOnboardHintIdNumber,
                      validator: (v) =>
                          _idType == '身份证' && !IdCardUtils.isValid(v)
                          ? l10n.employeeOnboardIdNumberInvalid
                          : _req(l10n, v, l10n.employeeFieldIdNumber),
                    ),
                    _text(
                      _phone,
                      '${l10n.employeeFieldPhone}*',
                      l10n.employeeOnboardHintPhone,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty)
                          return l10n.employeeOnboardPhoneRequired;
                        if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v.trim()))
                          return l10n.employeeOnboardPhoneInvalid;
                        return null;
                      },
                    ),
                    _text(
                      _email,
                      l10n.employeeFieldEmail,
                      l10n.employeeOnboardEmailOptional,
                    ),
                  ]),
                  _group(theme, l10n.employeeOnboardGroupOrg, [
                    DropdownButtonFormField<String>(
                      value: _departmentId,
                      decoration: InputDecoration(
                        labelText: '${l10n.employeeFieldDepartment}*',
                      ),
                      items: _depts
                          .map(
                            (d) => DropdownMenuItem(
                              value: d.id,
                              child: Text(
                                '${d.level} · ${d.name}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _departmentId = v),
                      validator: (v) => v == null || v.isEmpty
                          ? l10n.employeeOnboardPickDepartment
                          : null,
                    ),
                    GestureDetector(
                      onTap: _pickDate,
                      child: AbsorbPointer(
                        child: _text(
                          _hireDate,
                          '${l10n.employeeFieldHireDate}*',
                          l10n.employeeOnboardHireDateHint,
                          validator: (v) => (v == null || v.isEmpty)
                              ? l10n.employeeOnboardPickHireDate
                              : null,
                        ),
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      value: _employmentType,
                      decoration: InputDecoration(
                        labelText: '${l10n.employeeFieldEmploymentType}*',
                      ),
                      items: _employmentTypeCodes
                          .map(
                            (c) => DropdownMenuItem(
                              value: c,
                              child: Text(_employmentTypeLabel(l10n, c)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(
                        () => _employmentType = v ?? _employmentType,
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      value: _status,
                      decoration: InputDecoration(
                        labelText: '${l10n.employeeFieldStatus}*',
                      ),
                      items: _statusCodes
                          .map(
                            (c) => DropdownMenuItem(
                              value: c,
                              child: Text(_statusLabel(l10n, c)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _status = v ?? _status),
                    ),
                  ]),
                  _group(theme, l10n.employeeOnboardGroupPay, [
                    _text(
                      _baseSalary,
                      l10n.employeeFieldBaseSalary,
                      l10n.employeeOnboardEmailOptional,
                    ),
                    _text(
                      _bankBranch,
                      l10n.employeeFieldBankBranch,
                      l10n.employeeOnboardEmailOptional,
                    ),
                    _text(
                      _bankAccount,
                      l10n.employeeFieldBankAccount,
                      l10n.employeeOnboardEmailOptional,
                    ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        l10n.employeeOnboardNote,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.employeeOnboardSubmit),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _group(ThemeData theme, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _text(
    TextEditingController c,
    String label,
    String hint, {
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: TextFormField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        validator: validator,
      ),
    );
  }

  String? _req(AppLocalizations l10n, String? v, String label) =>
      (v == null || v.trim().isEmpty)
      ? l10n.employeeOnboardFieldRequired(label)
      : null;
}
