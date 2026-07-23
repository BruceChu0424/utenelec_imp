// 员工编辑页（真实后端）：部分更新——仅发送"已变更"字段，契合后端 UpdateEmployeeRequest 语义。
// 敏感 PII/薪资字段仅当变更且非空才回写（避免把脱敏占位误重新加密）。HR 角色拿明文，可正常编辑。
// 文档：docs/03-页面/员工编辑页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

class EmployeeEditPage extends ConsumerStatefulWidget {
  const EmployeeEditPage({super.key, required this.employeeId});
  final String employeeId;

  @override
  ConsumerState<EmployeeEditPage> createState() => _EmployeeEditPageState();
}

class _EmployeeEditPageState extends ConsumerState<EmployeeEditPage> {
  final _formKey = GlobalKey<FormState>();

  // 基本信息
  final _name = TextEditingController();
  final _birthDate = TextEditingController();
  final _ethnicity = TextEditingController();
  final _politicalStatus = TextEditingController();
  final _maritalStatus = TextEditingController();
  // 联系方式
  final _phone = TextEditingController();
  final _officePhone = TextEditingController();
  final _email = TextEditingController();
  final _huji = TextEditingController();
  final _residence = TextEditingController();
  // 组织信息
  final _workLocation = TextEditingController();
  final _seatNo = TextEditingController();
  // 薪资与银行
  final _baseSalary = TextEditingController();
  final _perfSalary = TextEditingController();
  final _socialBase = TextEditingController();
  final _housingBase = TextEditingController();
  final _bankBranch = TextEditingController();
  final _bankAccount = TextEditingController();

  static const _genderCodes = ['male', 'female'];
  static const _employmentTypeCodes = ['regular', 'dispatch', 'intern', 'outsource'];
  static const _statusCodes = ['active', 'probation', 'onLeave', 'resigned'];

  String _gender = 'male';
  String _employmentType = 'regular';
  String _status = 'active';
  String? _departmentId;

  List<DepartmentNode> _depts = const [];
  EmployeeProfile? _profile;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in [
      _name, _birthDate, _ethnicity, _politicalStatus, _maritalStatus,
      _phone, _officePhone, _email, _huji, _residence,
      _workLocation, _seatNo,
      _baseSalary, _perfSalary, _socialBase, _housingBase, _bankBranch, _bankAccount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ref.read(employeeRepositoryProvider).getById(widget.employeeId),
        ref.read(departmentRepositoryProvider).tree(),
      ]);
      if (!mounted) return;
      final p = results[0] as EmployeeProfile;
      final tree = results[1] as List<DepartmentNode>;
      _depts = _flatten(tree);
      _profile = p;
      _prefill(p);
      if (mounted) setState(() => _loading = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).employeeEditLoadFailed('');
        _loading = false;
      });
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

  void _prefill(EmployeeProfile p) {
    _name.text = p.fullName ?? '';
    _birthDate.text = p.birthDate ?? '';
    _ethnicity.text = p.ethnicity ?? '';
    _politicalStatus.text = p.politicalStatus ?? '';
    _maritalStatus.text = p.maritalStatus ?? '';
    _phone.text = p.phone ?? '';
    _officePhone.text = p.officePhone ?? '';
    _email.text = p.email ?? '';
    _huji.text = p.hujiAddress ?? '';
    _residence.text = p.residenceAddress ?? '';
    _workLocation.text = p.workLocation ?? '';
    _seatNo.text = p.seatNo ?? '';
    _baseSalary.text = p.baseSalary ?? '';
    _perfSalary.text = p.perfSalary ?? '';
    _socialBase.text = p.socialInsuranceBase ?? '';
    _housingBase.text = p.housingFundBase ?? '';
    _bankBranch.text = p.bankBranch ?? '';
    _bankAccount.text = p.bankAccount ?? '';

    _gender = _genderCodes.contains(p.gender) ? p.gender! : 'male';
    _employmentType =
        _employmentTypeCodes.contains(p.employmentType) ? p.employmentType! : 'regular';
    _status = _statusCodes.contains(p.status) ? p.status! : 'active';
    _departmentId =
        _depts.any((d) => d.id == p.departmentId) ? p.departmentId : null;
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _birthDate.text.isEmpty
          ? now.subtract(const Duration(days: 365 * 30))
          : DateTime.tryParse(_birthDate.text) ?? now,
      firstDate: DateTime(1940),
      lastDate: now,
    );
    if (d != null) _birthDate.text = DateFormat('yyyy-MM-dd').format(d);
  }

  /// 仅当当前值 ≠ 加载值才放入 payload（部分更新语义）。
  Map<String, dynamic> _buildPayload() {
    final p = _profile!;
    final body = <String, dynamic>{};
    void text(String key, TextEditingController c, String? loaded) {
      final cur = c.text.trim();
      if (cur != (loaded ?? '').trim()) body[key] = cur;
    }
    void code(String key, String? cur, String? loaded) {
      if (cur != loaded) body[key] = cur;
    }

    text('fullName', _name, p.fullName);
    code('gender', _gender, p.gender);
    text('birthDate', _birthDate, p.birthDate);
    text('ethnicity', _ethnicity, p.ethnicity);
    text('politicalStatus', _politicalStatus, p.politicalStatus);
    text('maritalStatus', _maritalStatus, p.maritalStatus);
    text('phone', _phone, p.phone);
    text('officePhone', _officePhone, p.officePhone);
    text('email', _email, p.email);
    text('hujiAddress', _huji, p.hujiAddress);
    text('residenceAddress', _residence, p.residenceAddress);
    code('departmentId', _departmentId, p.departmentId);
    code('employmentType', _employmentType, p.employmentType);
    code('status', _status, p.status);
    text('workLocation', _workLocation, p.workLocation);
    text('seatNo', _seatNo, p.seatNo);
    text('baseSalary', _baseSalary, p.baseSalary);
    text('perfSalary', _perfSalary, p.perfSalary);
    text('socialInsuranceBase', _socialBase, p.socialInsuranceBase);
    text('housingFundBase', _housingBase, p.housingFundBase);
    text('bankBranch', _bankBranch, p.bankBranch);
    text('bankAccount', _bankAccount, p.bankAccount);
    return body;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final body = _buildPayload();
    setState(() => _saving = true);
    try {
      await ref
          .read(employeeRepositoryProvider)
          .update(widget.employeeId, body);
      if (!mounted) return;
      context.appSuccess(l10n.employeeEditSaved);
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e, fallback: l10n.employeeEditSaveFailed);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.employeeEditSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _genderLabel(AppLocalizations l10n, String code) => switch (code) {
        'male' => l10n.genderMale,
        'female' => l10n.genderFemale,
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
        'resigned' => l10n.employeeStatusResigned,
        _ => code,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.employeeEditTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!),
                  ),
                )
              : Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    children: [
                      _section(l10n.employeeEditBasic, [
                        _text(_name, l10n.employeeFieldName, validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.employeeEditRequired;
                          }
                          return null;
                        }),
                        DropdownButtonFormField<String>(
                          initialValue: _gender,
                          decoration: _deco(l10n.employeeFieldGender),
                          items: _genderCodes
                              .map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(_genderLabel(l10n, c)),
                                  ))
                              .toList(),
                          onChanged: (v) => setState(() => _gender = v ?? _gender),
                        ),
                        GestureDetector(
                          onTap: _pickBirthDate,
                          child: AbsorbPointer(
                            child: _text(_birthDate, l10n.employeeFieldBirthDate),
                          ),
                        ),
                        _text(_ethnicity, l10n.employeeFieldEthnicity),
                        _text(_politicalStatus, l10n.employeeFieldPoliticalStatus),
                        _text(_maritalStatus, l10n.employeeFieldMaritalStatus),
                      ]),
                      _section(l10n.employeeEditContact, [
                        _text(_phone, l10n.employeeFieldPhone, validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return null;
                          if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(s)) {
                            return l10n.employeeOnboardPhoneInvalid;
                          }
                          return null;
                        }),
                        _text(_officePhone, l10n.employeeFieldOfficePhone),
                        _text(_email, l10n.employeeFieldEmail),
                        _text(_huji, l10n.employeeFieldHujiAddress),
                        _text(_residence, l10n.employeeFieldResidenceAddress),
                      ]),
                      _section(l10n.employeeEditOrg, [
                        DropdownButtonFormField<String>(
                          initialValue: _departmentId,
                          decoration: _deco(l10n.employeeFieldDepartment),
                          items: _depts
                              .map((d) => DropdownMenuItem(
                                    value: d.id,
                                    child: Text(
                                      '${d.level} · ${d.name}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: (v) => setState(() => _departmentId = v),
                          validator: (v) =>
                              v == null || v.isEmpty ? l10n.employeeEditRequired : null,
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _employmentType,
                          decoration: _deco(l10n.employeeFieldEmploymentType),
                          items: _employmentTypeCodes
                              .map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(_employmentTypeLabel(l10n, c)),
                                  ))
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _employmentType = v ?? _employmentType),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _status,
                          decoration: _deco(l10n.employeeFieldStatus),
                          items: _statusCodes
                              .map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(_statusLabel(l10n, c)),
                                  ))
                              .toList(),
                          onChanged: (v) => setState(() => _status = v ?? _status),
                        ),
                        _text(_workLocation, l10n.employeeFieldWorkLocation),
                        _text(_seatNo, l10n.employeeFieldSeatNo),
                      ]),
                      _section(l10n.employeeEditSalary, [
                        _text(_baseSalary, l10n.employeeFieldBaseSalary),
                        _text(_perfSalary, l10n.employeeFieldPerfSalary),
                        _text(_socialBase, l10n.employeeFieldSocialBase),
                        _text(_housingBase, l10n.employeeFieldHousingBase),
                        _text(_bankBranch, l10n.employeeFieldBankBranch),
                        _text(_bankAccount, l10n.employeeFieldBankAccount),
                      ]),
                    ],
                  ),
                ),
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
    );
  }

  Widget _section(String title, List<Widget> children) {
    final theme = Theme.of(context);
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
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
    String label, {
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: TextFormField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        validator: validator,
      ),
    );
  }

  InputDecoration _deco(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      );
}
