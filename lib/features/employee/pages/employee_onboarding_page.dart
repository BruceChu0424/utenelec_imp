// 入职办理页（真实后端）：单表单分组提交 → 后端原子建 employee+敏感+薪资+合同+轨迹+账号。
// 账号 = 工号；初始密码 = 身份证后六位（首登强制改）。
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120），分组为 UtenSectionHeader + UtenCard。
// 文档：docs/03-页面/入职流程页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../department/models/position.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../department/widgets/uten_position_picker.dart';
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
  Position? _position;
  bool _submitting = false;

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
        if (_position != null) 'positionId': _position!.id,
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
      // 顶部绿色通知——不再依赖 ScaffoldMessenger，避免与失败 notification 叠加。
      context.appSuccess(l10n.employeeOnboardSuccess);
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e, fallback: l10n.employeeOnboardSubmitFailed);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.employeeOnboardSubmitFailed);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeOnboardTitle,
        showBackButton: true,
      ),
      // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
      body: UtenContentContainer.narrow(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            children: [
              _group(l10n.employeeOnboardGroupProfile, [
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
                  initialValue: _idType,
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
                  validator: (v) => _idType == '身份证' && !IdCardUtils.isValid(v)
                      ? l10n.employeeOnboardIdNumberInvalid
                      : _req(l10n, v, l10n.employeeFieldIdNumber),
                ),
                _text(
                  _phone,
                  '${l10n.employeeFieldPhone}*',
                  l10n.employeeOnboardHintPhone,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return l10n.employeeOnboardPhoneRequired;
                    }
                    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v.trim())) {
                      return l10n.employeeOnboardPhoneInvalid;
                    }
                    return null;
                  },
                ),
                _text(
                  _email,
                  l10n.employeeFieldEmail,
                  l10n.employeeOnboardEmailOptional,
                ),
              ]),
              _group(l10n.employeeOnboardGroupOrg, [
                UtenDepartmentPicker(
                  mode: UtenDepartmentPickerMode.single,
                  label: '${l10n.employeeFieldDepartment}*',
                  onChanged: (sel) => setState(() {
                    _departmentId = sel.isEmpty ? null : sel.first.id;
                    _position = null;
                  }),
                  validator: (sel) =>
                      sel.isEmpty ? l10n.employeeOnboardPickDepartment : null,
                ),
                UtenPositionPicker(
                  departmentId: _departmentId,
                  label: l10n.employeeFieldPosition,
                  value: _position,
                  onChanged: (p) => setState(() => _position = p),
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
                  initialValue: _employmentType,
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
                  onChanged: (v) =>
                      setState(() => _employmentType = v ?? _employmentType),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _status,
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
              _group(l10n.employeeOnboardGroupPay, [
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
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                child: Builder(
                  builder: (context) {
                    final theme = Theme.of(context);
                    return Container(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: UtenRadius.lgAll,
                      ),
                      child: Text(
                        l10n.employeeOnboardNote,
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  },
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
              const SizedBox(height: UtenSpacing.s24),
            ],
          ),
        ),
      ),
    );
  }

  /// 分组：UtenSectionHeader（卡外标题）+ UtenCard（字段），字段间距 12、区块间距 24。
  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(title: title),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i < children.length - 1)
                    const SizedBox(height: UtenSpacing.s12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _text(
    TextEditingController c,
    String label,
    String hint, {
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      validator: validator,
    );
  }

  String? _req(AppLocalizations l10n, String? v, String label) =>
      (v == null || v.trim().isEmpty)
      ? l10n.employeeOnboardFieldRequired(label)
      : null;
}
